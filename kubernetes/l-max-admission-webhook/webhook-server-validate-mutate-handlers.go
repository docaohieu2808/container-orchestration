// L-MAX: Admission Webhook Server — Validate and Mutate Handlers
// This HTTPS server handles AdmissionReview requests from the Kubernetes API server.
// Two endpoints:
//   /mutate-apps-example-com-v1alpha1-webapp  — sets default resource limits if omitted
//   /validate-apps-example-com-v1alpha1-webapp — rejects images tagged :latest
//
// TLS is REQUIRED. The API server verifies the webhook cert against caBundle in the
// WebhookConfiguration. Use cert-manager or generate certs with:
//   openssl req -x509 -newkey rsa:4096 -keyout tls.key -out tls.crt -days 365 -nodes \
//     -subj "/CN=webapp-webhook-service.demo.svc"
//
// Build: go build -o webhook-server ./...
// Deploy: docker build + push, create a Service named webapp-webhook-service in namespace demo
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	tlsCertFile = "/etc/webhook/certs/tls.crt" // Mounted from a Secret (type: kubernetes.io/tls)
	tlsKeyFile  = "/etc/webhook/certs/tls.key"
)

// WebApp is a minimal struct matching the CRD spec for JSON unmarshalling.
type WebApp struct {
	Spec struct {
		Image    string `json:"image"`
		Replicas int    `json:"replicas"`
		Port     int    `json:"port"`
	} `json:"spec"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/mutate-apps-example-com-v1alpha1-webapp", mutateHandler)
	mux.HandleFunc("/validate-apps-example-com-v1alpha1-webapp", validateHandler)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	server := &http.Server{
		Addr:    ":8443",
		Handler: mux,
	}

	log.Println("Starting webhook server on :8443 (TLS)")
	if err := server.ListenAndServeTLS(tlsCertFile, tlsKeyFile); err != nil {
		log.Fatalf("failed to start webhook server: %v", err)
	}
}

// mutateHandler sets default port to 80 if not specified (MutatingAdmissionWebhook).
func mutateHandler(w http.ResponseWriter, r *http.Request) {
	review, err := decodeAdmissionReview(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var webapp WebApp
	if err := json.Unmarshal(review.Request.Object.Raw, &webapp); err != nil {
		writeResponse(w, review.Request.UID, false, "failed to parse WebApp", nil)
		return
	}

	var patches []map[string]interface{}

	// Mutation 1: set default port to 80 if omitted or zero
	if webapp.Spec.Port == 0 {
		patches = append(patches, map[string]interface{}{
			"op":    "add",
			"path":  "/spec/port",
			"value": 80,
		})
	}

	// Mutation 2: set default replicas to 1 if omitted or zero
	if webapp.Spec.Replicas == 0 {
		patches = append(patches, map[string]interface{}{
			"op":    "add",
			"path":  "/spec/replicas",
			"value": 1,
		})
	}

	var patchBytes []byte
	if len(patches) > 0 {
		patchBytes, _ = json.Marshal(patches)
	}

	writeResponse(w, review.Request.UID, true, "mutated defaults", patchBytes)
}

// validateHandler rejects WebApp objects that use the :latest image tag (ValidatingAdmissionWebhook).
func validateHandler(w http.ResponseWriter, r *http.Request) {
	review, err := decodeAdmissionReview(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var webapp WebApp
	if err := json.Unmarshal(review.Request.Object.Raw, &webapp); err != nil {
		writeResponse(w, review.Request.UID, false, "failed to parse WebApp", nil)
		return
	}

	// Validation rule: reject images tagged :latest (non-deterministic deployments)
	if strings.HasSuffix(webapp.Spec.Image, ":latest") || !strings.Contains(webapp.Spec.Image, ":") {
		writeResponse(w, review.Request.UID, false,
			fmt.Sprintf("image %q must have an explicit version tag (not :latest)", webapp.Spec.Image), nil)
		return
	}

	// Validation rule: replicas must be >= 1
	if webapp.Spec.Replicas < 1 {
		writeResponse(w, review.Request.UID, false, "spec.replicas must be >= 1", nil)
		return
	}

	writeResponse(w, review.Request.UID, true, "validation passed", nil)
}

// decodeAdmissionReview parses the AdmissionReview from the request body.
func decodeAdmissionReview(r *http.Request) (*admissionv1.AdmissionReview, error) {
	var review admissionv1.AdmissionReview
	if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
		return nil, fmt.Errorf("failed to decode AdmissionReview: %w", err)
	}
	if review.Request == nil {
		return nil, fmt.Errorf("AdmissionReview.Request is nil")
	}
	return &review, nil
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
