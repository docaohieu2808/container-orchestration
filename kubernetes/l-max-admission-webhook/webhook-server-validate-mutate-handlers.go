// L-MAX: Admission Webhook Server — Validate and Mutate Handlers
// This HTTPS server handles AdmissionReview requests from the Kubernetes API server.
// Two endpoints:
//
//	/mutate-apps-example-com-v1alpha1-webapp   — adds the managed-by label if it is missing
//	/validate-apps-example-com-v1alpha1-webapp — rejects images without an explicit tag (or tagged :latest)
//
// Request order in the API server: defaulting (CRD defaults) -> mutating webhooks -> schema
// validation -> validating webhooks. That is why validation here does not repeat what the CRD schema
// already enforces (replicas range, required fields).
//
// TLS is REQUIRED, and the serving certificate must carry the Service DNS name in its SAN list
// (Go rejects CN-only certificates). gen-webhook-certs.sh in this directory creates a CA and a
// correct certificate, stores them in the webhook-tls Secret, and fills in caBundle.
//
// Build: go build -o webhook-server .
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

const (
	tlsCertFile = "/etc/webhook/certs/tls.crt" // Mounted from a Secret (type: kubernetes.io/tls)
	tlsKeyFile  = "/etc/webhook/certs/tls.key"

	managedByLabel = "app.kubernetes.io/managed-by"
	managedByValue = "webapp-operator"
	maxBodyBytes   = 1 << 20 // an AdmissionReview for a WebApp is tiny; cap what we read
)

// WebApp is a minimal struct matching the CRD for JSON unmarshalling.
type WebApp struct {
	Metadata struct {
		Labels map[string]string `json:"labels"`
	} `json:"metadata"`
	Spec struct {
		Image    string `json:"image"`
		Replicas int    `json:"replicas"`
		Port     int    `json:"port"`
	} `json:"spec"`
}

func main() {
	server := &http.Server{
		Addr:              ":8443",
		Handler:           newMux(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Println("Starting webhook server on :8443 (TLS)")
	if err := server.ListenAndServeTLS(tlsCertFile, tlsKeyFile); err != nil {
		log.Fatalf("failed to start webhook server: %v", err)
	}
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/mutate-apps-example-com-v1alpha1-webapp", mutateHandler)
	mux.HandleFunc("/validate-apps-example-com-v1alpha1-webapp", validateHandler)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	return mux
}

// jsonPatchOp is one RFC 6902 operation.
type jsonPatchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

// mutateHandler labels every WebApp with the controller that manages it (MutatingAdmissionWebhook).
func mutateHandler(w http.ResponseWriter, r *http.Request) {
	review, webapp, err := decode(w, r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var patches []jsonPatchOp
	if webapp.Metadata.Labels == nil {
		// No labels map at all: the whole map must be added, a deeper path would not exist yet.
		patches = append(patches, jsonPatchOp{Op: "add", Path: "/metadata/labels", Value: map[string]string{managedByLabel: managedByValue}})
	} else if _, ok := webapp.Metadata.Labels[managedByLabel]; !ok {
		patches = append(patches, jsonPatchOp{Op: "add", Path: "/metadata/labels/" + escapeJSONPointer(managedByLabel), Value: managedByValue})
	}

	var patchBytes []byte
	if len(patches) > 0 {
		patchBytes, err = json.Marshal(patches)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
	writeResponse(w, review.Request.UID, true, "mutated defaults", patchBytes)
}

// validateHandler rejects WebApp objects that use an untagged or :latest image (ValidatingAdmissionWebhook).
func validateHandler(w http.ResponseWriter, r *http.Request) {
	review, webapp, err := decode(w, r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if !hasExplicitTag(webapp.Spec.Image) {
		writeResponse(w, review.Request.UID, false,
			fmt.Sprintf("image %q must have an explicit version tag or digest (not :latest)", webapp.Spec.Image), nil)
		return
	}
	writeResponse(w, review.Request.UID, true, "validation passed", nil)
}

// hasExplicitTag reports whether an image reference pins a version: a digest, or a tag other than
// "latest". Only the last path segment is inspected, so "registry:5000/app" (a registry port, no tag)
// is correctly seen as untagged.
func hasExplicitTag(image string) bool {
	if strings.Contains(image, "@sha256:") {
		return true
	}
	last := image[strings.LastIndex(image, "/")+1:]
	i := strings.LastIndex(last, ":")
	return i >= 0 && last[i+1:] != "" && last[i+1:] != "latest"
}

// escapeJSONPointer escapes a key for use inside a JSON pointer (RFC 6901): "~" -> "~0", "/" -> "~1".
func escapeJSONPointer(s string) string {
	return strings.NewReplacer("~", "~0", "/", "~1").Replace(s)
}

// decode parses the AdmissionReview from the request body and the WebApp object inside it.
func decode(w http.ResponseWriter, r *http.Request) (*admissionv1.AdmissionReview, *WebApp, error) {
	var review admissionv1.AdmissionReview
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes)).Decode(&review); err != nil {
		return nil, nil, fmt.Errorf("failed to decode AdmissionReview: %w", err)
	}
	if review.Request == nil {
		return nil, nil, errors.New("AdmissionReview.Request is nil")
	}
	var webapp WebApp
	if err := json.Unmarshal(review.Request.Object.Raw, &webapp); err != nil {
		return nil, nil, fmt.Errorf("failed to parse WebApp: %w", err)
	}
	return &review, &webapp, nil
}

// writeResponse writes an AdmissionReview response with optional JSON patch.
func writeResponse(w http.ResponseWriter, uid types.UID, allowed bool, message string, patch []byte) {
	response := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: &admissionv1.AdmissionResponse{
			UID:     uid,
			Allowed: allowed,
			Result: &metav1.Status{
				Message: message,
			},
		},
	}

	if patch != nil {
		patchType := admissionv1.PatchTypeJSONPatch
		response.Response.Patch = patch
		response.Response.PatchType = &patchType
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("failed to write response: %v", err)
	}
}
