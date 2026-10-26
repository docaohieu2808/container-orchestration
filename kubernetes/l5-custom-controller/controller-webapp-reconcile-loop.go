// L5: Custom Controller — WebApp Reconcile Loop
// The Reconciler implements the core Operator pattern:
//
//	Watch (informer cache) → Enqueue → Reconcile (desired vs actual state) → Act
//
// controller-runtime handles the informer/workqueue plumbing automatically.
// We implement only the Reconcile() method — called whenever a WebApp object
// is created, updated, deleted, or when a child resource changes.
//
// Key concepts:
//   - Idempotent: Reconcile must be safe to call multiple times with the same result.
//   - Ownership: child resources (Deployment, Service) have OwnerReference set to WebApp.
//   - CreateOrUpdate: the mutate function declares ALL fields the controller owns, so a change to
//     any of them in the WebApp (replicas, image, port, env) reaches the child object.
//   - Status: update WebApp.Status after each reconcile to reflect current state.
package main

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	appsv1alpha1 "github.com/docaohieu2808/container-orchestration/kubernetes/l5-custom-controller/api/v1alpha1"
)

const (
	phasePending = "Pending"
	phaseRunning = "Running"
	phaseFailed  = "Failed"

	defaultPort = 80
)

// WebAppReconciler reconciles WebApp custom resources.
type WebAppReconciler struct {
	client.Client                 // Embedded client for API server calls (Get, Create, Update, Delete)
	Scheme        *runtime.Scheme // Scheme for type registration and OwnerReference GVK lookup
}

// Reconcile is the main reconcile loop — called by controller-runtime on every event.
// It ensures the actual cluster state matches the desired state declared in the WebApp spec.
func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Fetch the WebApp instance from the cache
	webapp := &appsv1alpha1.WebApp{}
	if err := r.Get(ctx, req.NamespacedName, webapp); err != nil {
		if errors.IsNotFound(err) {
			// Object deleted before reconcile ran — nothing to do (child resources cleaned via OwnerReference GC)
			logger.Info("WebApp not found, likely deleted", "name", req.NamespacedName)
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to get WebApp: %w", err)
	}

	// 2. Reconcile child Deployment
	dep, err := r.reconcileDeployment(ctx, webapp)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to reconcile Deployment: %w", err)
	}

	// 3. Reconcile child Service
	if err := r.reconcileService(ctx, webapp); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to reconcile Service: %w", err)
	}

	// 4. Update status to reflect current available replicas
	if err := r.updateStatus(ctx, req.NamespacedName, dep); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to update status: %w", err)
	}

	logger.Info("Reconciled WebApp", "name", webapp.Name, "replicas", webapp.Spec.Replicas)
	return ctrl.Result{}, nil
}

// containerPort returns the port to expose, falling back to the CRD default if the field is unset.
func containerPort(webapp *appsv1alpha1.WebApp) int32 {
	if webapp.Spec.Port == 0 {
		return defaultPort
	}
	return webapp.Spec.Port
}

// reconcileDeployment creates or updates the child Deployment and returns it (with live status).
func (r *WebAppReconciler) reconcileDeployment(ctx context.Context, webapp *appsv1alpha1.WebApp) (*appsv1.Deployment, error) {
	dep := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: webapp.Name, Namespace: webapp.Namespace}}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, dep, func() error {
		labels := map[string]string{"app": webapp.Name}
		replicas := webapp.Spec.Replicas

		dep.Spec.Replicas = &replicas
		if dep.CreationTimestamp.IsZero() {
			// spec.selector is immutable after creation, so only set it on create.
			dep.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
		}
		dep.Spec.Template.Labels = labels

		env := make([]corev1.EnvVar, 0, len(webapp.Spec.Env))
		for _, e := range webapp.Spec.Env {
			env = append(env, corev1.EnvVar{Name: e.Name, Value: e.Value})
		}
		if len(dep.Spec.Template.Spec.Containers) == 0 {
			dep.Spec.Template.Spec.Containers = []corev1.Container{{}}
		}
		c := &dep.Spec.Template.Spec.Containers[0]
		c.Name = "webapp"
		c.Image = webapp.Spec.Image
		c.Ports = []corev1.ContainerPort{{ContainerPort: containerPort(webapp), Protocol: corev1.ProtocolTCP}}
		c.Env = env

		// Set OwnerReference so GC deletes the Deployment when WebApp is deleted
		return controllerutil.SetControllerReference(webapp, dep, r.Scheme)
	})
	if err != nil {
		return nil, err
	}
	return dep, nil
}

// reconcileService creates or updates the ClusterIP Service for the WebApp.
func (r *WebAppReconciler) reconcileService(ctx context.Context, webapp *appsv1alpha1.WebApp) error {
	svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: webapp.Name, Namespace: webapp.Namespace}}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		port := containerPort(webapp)
		svc.Spec.Type = corev1.ServiceTypeClusterIP
		svc.Spec.Selector = map[string]string{"app": webapp.Name}
		svc.Spec.Ports = []corev1.ServicePort{{
			Name:       "http",
			Protocol:   corev1.ProtocolTCP,
			Port:       port,
			TargetPort: intstr.FromInt32(port),
		}}
		return controllerutil.SetControllerReference(webapp, svc, r.Scheme)
	})
	return err
}

// updateStatus reflects the child Deployment's state into WebApp.Status.
// It re-reads the WebApp inside RetryOnConflict so a stale resourceVersion never fails the reconcile.
func (r *WebAppReconciler) updateStatus(ctx context.Context, key client.ObjectKey, dep *appsv1.Deployment) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		webapp := &appsv1alpha1.WebApp{}
		if err := r.Get(ctx, key, webapp); err != nil {
			return client.IgnoreNotFound(err)
		}

		phase := phasePending
		switch {
		case deploymentFailed(dep):
			phase = phaseFailed
		case dep.Status.AvailableReplicas == webapp.Spec.Replicas:
			phase = phaseRunning
		}

		if webapp.Status.AvailableReplicas == dep.Status.AvailableReplicas && webapp.Status.Phase == phase {
			return nil // nothing changed: skip the write, which would only trigger another reconcile
		}
		webapp.Status.AvailableReplicas = dep.Status.AvailableReplicas
		webapp.Status.Phase = phase

		// Status().Update() writes only the status subresource (avoids conflicts on spec)
		return r.Status().Update(ctx, webapp)
	})
}

// deploymentFailed reports whether the Deployment gave up rolling out (ProgressDeadlineExceeded).
func deploymentFailed(dep *appsv1.Deployment) bool {
	for _, cond := range dep.Status.Conditions {
		if cond.Type == appsv1.DeploymentProgressing && cond.Status == corev1.ConditionFalse &&
			cond.Reason == "ProgressDeadlineExceeded" {
			return true
		}
	}
	return false
}

// SetupWithManager registers this controller with the Manager.
// Owns(Deployment) and Owns(Service) ensure re-queue when child resources change.
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&appsv1alpha1.WebApp{}). // Watch WebApp objects (primary resource)
		Owns(&appsv1.Deployment{}).  // Re-queue WebApp when owned Deployment changes
		Owns(&corev1.Service{}).     // Re-queue WebApp when owned Service changes
		Complete(r)
}
