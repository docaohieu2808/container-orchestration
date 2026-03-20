// L-MAX: Go Module — Admission Webhook Server Dependencies
// Minimal dependencies: only k8s.io/api for AdmissionReview types.
// No controller-runtime needed — this is a plain HTTPS server.
//
// To initialize: go mod tidy
// To build:      go build -o webhook-server ./...
module example.com/webapp-webhook

go 1.21

require (
	k8s.io/api v0.28.4
	k8s.io/apimachinery v0.28.4
)

require (
	github.com/go-logr/logr v1.3.0 // indirect
	k8s.io/utils v0.0.0-20231127182322-b307cd553661 // indirect
	sigs.k8s.io/json v0.0.0-20221116044647-bc3834ca7abd // indirect
	sigs.k8s.io/yaml v1.4.0 // indirect
)
