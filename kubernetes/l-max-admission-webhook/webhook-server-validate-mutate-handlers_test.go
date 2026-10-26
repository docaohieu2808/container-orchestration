package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func post(t *testing.T, path, object string) admissionv1.AdmissionReview {
	t.Helper()
	body, err := json.Marshal(admissionv1.AdmissionReview{
		Request: &admissionv1.AdmissionRequest{UID: "abc", Object: runtime.RawExtension{Raw: []byte(object)}},
	})
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	newMux().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var out admissionv1.AdmissionReview
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.Response == nil || out.Response.UID != "abc" {
		t.Fatalf("response must echo the request UID: %+v", out.Response)
	}
	return out
}

func TestHasExplicitTag(t *testing.T) {
	cases := map[string]bool{
		"nginx:1.30.6-alpine":           true,
		"registry:5000/app:v1":          true,
		"registry:5000/app":             false, // the colon is a registry port, not a tag
		"nginx":                         false,
		"nginx:latest":                  false,
		"ghcr.io/o/app:latest":          false,
		"nginx:":                        false,
		"app@sha256:0123456789abcdef":   true,
		"registry:5000/o/app:1.2.3":     true,
		"registry:5000/o/app:latest":    false,
		"registry.example.com/team/x":   false,
		"registry.example.com/team/x:2": true,
	}
	for image, want := range cases {
		if got := hasExplicitTag(image); got != want {
			t.Errorf("hasExplicitTag(%q) = %v, want %v", image, got, want)
		}
	}
}

func TestValidateRejectsLatest(t *testing.T) {
	out := post(t, "/validate-apps-example-com-v1alpha1-webapp", `{"spec":{"image":"nginx:latest","replicas":2}}`)
	if out.Response.Allowed {
		t.Fatal("expected :latest to be rejected")
	}
	out = post(t, "/validate-apps-example-com-v1alpha1-webapp", `{"spec":{"image":"nginx:1.30.6-alpine","replicas":2}}`)
	if !out.Response.Allowed {
		t.Fatalf("expected tagged image to pass: %+v", out.Response.Result)
	}
}

func TestMutateAddsManagedByLabel(t *testing.T) {
	// No labels at all: the whole map is added.
	out := post(t, "/mutate-apps-example-com-v1alpha1-webapp", `{"metadata":{},"spec":{"image":"a:1","replicas":1}}`)
	if !out.Response.Allowed || out.Response.PatchType == nil || *out.Response.PatchType != admissionv1.PatchTypeJSONPatch {
		t.Fatalf("expected a JSON patch: %+v", out.Response)
	}
	var patches []jsonPatchOp
	if err := json.Unmarshal(out.Response.Patch, &patches); err != nil || len(patches) != 1 || patches[0].Path != "/metadata/labels" {
		t.Fatalf("patch = %s (err %v)", out.Response.Patch, err)
	}

	// Existing labels: add just the one key, with the slash escaped in the pointer.
	out = post(t, "/mutate-apps-example-com-v1alpha1-webapp", `{"metadata":{"labels":{"a":"b"}},"spec":{"image":"a:1","replicas":1}}`)
	if err := json.Unmarshal(out.Response.Patch, &patches); err != nil || patches[0].Path != "/metadata/labels/app.kubernetes.io~1managed-by" {
		t.Fatalf("patch = %s (err %v)", out.Response.Patch, err)
	}

	// Already labelled: nothing to patch.
	out = post(t, "/mutate-apps-example-com-v1alpha1-webapp", `{"metadata":{"labels":{"app.kubernetes.io/managed-by":"helm"}},"spec":{"image":"a:1","replicas":1}}`)
	if len(out.Response.Patch) != 0 {
		t.Fatalf("expected no patch, got %s", out.Response.Patch)
	}
}

func TestMalformedBodyIsBadRequest(t *testing.T) {
	rec := httptest.NewRecorder()
	newMux().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/validate-apps-example-com-v1alpha1-webapp", bytes.NewReader([]byte("not json"))))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", rec.Code)
	}
}
