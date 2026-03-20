// L5: Custom Controller — WebApp Reconcile Loop
// The Reconciler implements the core Operator pattern:
//   Watch (informer cache) → Enqueue → Reconcile (desired vs actual state) → Act
//
// controller-runtime handles the informer/workqueue plumbing automatically.
// We implement only the Reconcile() method — called whenever a WebApp object
// is created, updated, deleted, or when a child resource changes.
//
// Key concepts:
//   - Idempotent: Reconcile must be safe to call multiple times with the same result.
//   - Ownership: child resources (Deployment, Service) have OwnerReference set to WebApp.
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
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	appsexamplev1alpha1 "example.com/webapp-operator/api/v1alpha1"
)

// WebAppReconciler reconciles WebApp custom resources.
type WebAppReconciler struct {
	client.Client                  // Embedded client for API server calls (Get, Create, Update, Delete)
	Scheme        *runtime.Scheme  // Scheme for type registration and OwnerReference GVK lookup
}

// Reconcile is the main reconcile loop — called by controller-runtime on every event.
// It ensures the actual cluster state matches the desired state declared in the WebApp spec.
//
//nolint:cyclop
func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Fetch the WebApp instance from the cache
	webapp := &appsexamplev1alpha1.WebApp{}
	if err := r.Get(ctx, req.NamespacedName, webapp); err != nil {
		if errors.IsNotFound(err) {
			// Object deleted before reconcile ran — nothing to do (child resources cleaned via OwnerReference GC)
			logger.Info("WebApp not found, likely deleted", "name", req.NamespacedName)
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("failed to get WebApp: %w", err)
	}

	// 2. Reconcile child Deployment
	if err := r.reconcileDeployment(ctx, webapp); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to reconcile Deployment: %w", err)
	}

	// 3. Reconcile child Service
	if err := r.reconcileService(ctx, webapp); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to reconcile Service: %w", err)
	}

	// 4. Update status to reflect current available replicas
	if err := r.updateStatus(ctx, webapp); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to update status: %w", err)
	}

	logger.Info("Reconciled WebApp", "name", webapp.Name, "replicas", webapp.Spec.Replicas)
	return ctrl.Result{}, nil
}

// reconcileDeployment creates or updates the child Deployment for the WebApp.
func (r *WebAppReconciler) reconcileDeployment(ctx context.Context, webapp *appsexamplev1alpha1.WebApp) error {
	replicas := int32(webapp.Spec.Replicas) //nolint:gosec

	desired := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": webapp.Name},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": webapp.Name},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "webapp",
							Image: webapp.Spec.Image,
							Ports: []corev1.ContainerPort{
								{ContainerPort: int32(webapp.Spec.Port)}, //nolint:gosec
							},
						},
					},
				},
			},
		},
	}

	// Set OwnerReference so GC deletes the Deployment when WebApp is deleted
	if err := controllerutil.SetControllerReference(webapp, desired, r.Scheme); err != nil {
		return err
	}

	// CreateOrUpdate: fetch existing, compare, update if different (idempotent)
	existing := &appsv1.Deployment{}
	err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, existing)
	if errors.IsNotFound(err) {
		return r.Create(ctx, desired)
	}
	if err != nil {
		return err
	}

	// Update replicas and image if they changed
	existing.Spec.Replicas = desired.Spec.Replicas
	existing.Spec.Template.Spec.Containers[0].Image = desired.Spec.Template.Spec.Containers[0].Image
	return r.Update(ctx, existing)
}

// reconcileService creates or ensures a ClusterIP Service exists for the WebApp.
func (r *WebAppReconciler) reconcileService(ctx context.Context, webapp *appsexamplev1alpha1.WebApp) error {
	desired := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": webapp.Name},
			Ports: []corev1.ServicePort{
				{Port: int32(webapp.Spec.Port)}, //nolint:gosec
			},
			Type: corev1.ServiceTypeClusterIP,
		},
	}

	if err := controllerutil.SetControllerReference(webapp, desired, r.Scheme); err != nil {
		return err
	}

	existing := &corev1.Service{}
	err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, existing)
	if errors.IsNotFound(err) {
		return r.Create(ctx, desired)
	}
	return err
}

// updateStatus fetches the child Deployment and reflects available replicas into WebApp.Status.
func (r *WebAppReconciler) updateStatus(ctx context.Context, webapp *appsexamplev1alpha1.WebApp) error {
	dep := &appsv1.Deployment{}
	if err := r.Get(ctx, types.NamespacedName{Name: webapp.Name, Namespace: webapp.Namespace}, dep); err != nil {
		return err
	}

	webapp.Status.AvailableReplicas = int(dep.Status.AvailableReplicas)
	if dep.Status.AvailableReplicas == *dep.Spec.Replicas {
		webapp.Status.Phase = "Running"
	} else {
		webapp.Status.Phase = "Pending"
	}

	// Use Status().Update() to write only the status subresource (avoids conflicts on spec)
	return r.Status().Update(ctx, webapp)
}

// SetupWithManager registers this controller with the Manager.
// Owns(Deployment) and Owns(Service) ensure re-queue when child resources change.
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&appsexamplev1alpha1.WebApp{}).  // Watch WebApp objects (primary resource)
		Owns(&appsv1.Deployment{}).          // Re-queue WebApp when owned Deployment changes
		Owns(&corev1.Service{}).             // Re-queue WebApp when owned Service changes
		Complete(r)
}
