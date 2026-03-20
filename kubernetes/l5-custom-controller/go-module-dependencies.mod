// L5: Go Module — Custom Controller Dependencies
// Uses controller-runtime (sigs.k8s.io/controller-runtime) which wraps:
//   - client-go: Kubernetes API client, informers, workqueue
//   - apimachinery: core types, runtime.Scheme, RESTMapper
//   - controller-runtime: Manager, Reconciler, Builder DSL
//
// To initialize: go mod tidy
// To build:      go build -o manager ./...
// Compatible with Kubernetes 1.28+ / K3s v1.28+
module example.com/webapp-operator

go 1.21

require (
	k8s.io/api v0.28.4
	k8s.io/apimachinery v0.28.4
	k8s.io/client-go v0.28.4
	sigs.k8s.io/controller-runtime v0.16.3
)

require (
	github.com/go-logr/logr v1.3.0 // indirect
	github.com/go-logr/zapr v1.3.0 // indirect
	go.uber.org/zap v1.26.0 // indirect
	golang.org/x/net v0.17.0 // indirect
	golang.org/x/oauth2 // indirect
	k8s.io/utils v0.0.0-20231127182322-b307cd553661 // indirect
	sigs.k8s.io/yaml v1.4.0 // indirect
)
