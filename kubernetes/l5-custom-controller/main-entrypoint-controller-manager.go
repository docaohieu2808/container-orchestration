// L5: Custom Controller — Main Entrypoint (Controller Manager)
// This is the entry point for a Kubernetes custom controller written in Go.
// It uses controller-runtime (sigs.k8s.io/controller-runtime) which provides:
//   - Manager: handles shared caches, clients, leader election, metrics
//   - Controller: wires informers and reconcile loop together
//   - Client: read/write Kubernetes objects via the API server
//
// Build:       make build            (or: go build -o manager .)
// Run locally: KUBECONFIG=~/.kube/config go run .   (the CRD from l4 must be applied first)
// Deploy:      make docker-build, then apply l4-operators-crds/operator-controller-deployment-with-rbac.yaml
package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	appsv1alpha1 "github.com/docaohieu2808/container-orchestration/kubernetes/l5-custom-controller/api/v1alpha1"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	// Register the built-in Kubernetes types (Deployment, Service, ...) and our WebApp type.
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(appsv1alpha1.AddToScheme(scheme))
}

func main() {
	var (
		metricsAddr          string
		enableLeaderElection bool
		probeAddr            string
		watchNamespace       string
	)

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address for the metrics endpoint.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address for health probes.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false,
		"Enable leader election for controller manager (required for HA — only one replica reconciles at a time).")
	flag.StringVar(&watchNamespace, "namespace", "", "Namespace to watch. Empty string means all namespaces.")
	zapOpts := zap.Options{Development: true}
	zapOpts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zapOpts)))

	// controller-runtime v0.15+ moved these settings into dedicated option structs:
	//   MetricsBindAddress -> Metrics.BindAddress,  Namespace -> Cache.DefaultNamespaces,
	//   Port/Host/CertDir  -> WebhookServer (only needed by a manager that also serves webhooks;
	//   this one does not — the admission webhook in l-max is a separate binary).
	opts := ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "webapp-operator.apps.example.com",
	}
	if watchNamespace != "" { // "" = cluster-wide watch
		opts.Cache = cache.Options{DefaultNamespaces: map[string]cache.Config{watchNamespace: {}}}
	}

	// Manager holds the shared cache (informers), client, and controller registrations.
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), opts)
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	// Register the WebAppReconciler with the manager
	if err = (&WebAppReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "WebApp")
		os.Exit(1)
	}

	// Health check endpoints for Kubernetes liveness/readiness probes
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}
