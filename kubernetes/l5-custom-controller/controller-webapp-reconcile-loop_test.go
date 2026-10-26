package main

import (
	"context"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	appsv1alpha1 "github.com/docaohieu2808/container-orchestration/kubernetes/l5-custom-controller/api/v1alpha1"
)

var testKey = types.NamespacedName{Namespace: "demo", Name: "my-webapp"}

func newReconciler(t *testing.T, objs ...client.Object) *WebAppReconciler {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := appsv1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	c := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(objs...).
		WithStatusSubresource(&appsv1alpha1.WebApp{}, &appsv1.Deployment{}).
		Build()
	return &WebAppReconciler{Client: c, Scheme: s}
}

func sampleWebApp() *appsv1alpha1.WebApp {
	return &appsv1alpha1.WebApp{
		ObjectMeta: metav1.ObjectMeta{Name: testKey.Name, Namespace: testKey.Namespace, UID: "uid-1"},
		Spec: appsv1alpha1.WebAppSpec{
			Image:    "nginxinc/nginx-unprivileged:1.30.6-alpine",
			Replicas: 3,
			Port:     8080,
			Env:      []appsv1alpha1.EnvVar{{Name: "APP_ENV", Value: "production"}},
		},
	}
}

func reconcileOnce(t *testing.T, r *WebAppReconciler) {
	t.Helper()
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
}

func TestReconcileCreatesDeploymentAndService(t *testing.T) {
	r := newReconciler(t, sampleWebApp())
	reconcileOnce(t, r)
	ctx := context.Background()

	dep := &appsv1.Deployment{}
	if err := r.Get(ctx, testKey, dep); err != nil {
		t.Fatalf("deployment not created: %v", err)
	}
	if *dep.Spec.Replicas != 3 {
		t.Errorf("replicas = %d, want 3", *dep.Spec.Replicas)
	}
	c := dep.Spec.Template.Spec.Containers[0]
	if c.Image != "nginxinc/nginx-unprivileged:1.30.6-alpine" || c.Ports[0].ContainerPort != 8080 {
		t.Errorf("container = %s port %d", c.Image, c.Ports[0].ContainerPort)
	}
	if len(c.Env) != 1 || c.Env[0].Name != "APP_ENV" || c.Env[0].Value != "production" {
		t.Errorf("env = %+v, want spec.env mapped into the container", c.Env)
	}
	if !metav1.IsControlledBy(dep, sampleWebApp()) {
		t.Errorf("deployment is not owned by the WebApp: %+v", dep.OwnerReferences)
	}

	svc := &corev1.Service{}
	if err := r.Get(ctx, testKey, svc); err != nil {
		t.Fatalf("service not created: %v", err)
	}
	if svc.Spec.Ports[0].Port != 8080 {
		t.Errorf("service port = %d, want 8080", svc.Spec.Ports[0].Port)
	}
}

func TestReconcilePropagatesSpecChanges(t *testing.T) {
	r := newReconciler(t, sampleWebApp())
	reconcileOnce(t, r)
	ctx := context.Background()

	webapp := &appsv1alpha1.WebApp{}
	if err := r.Get(ctx, testKey, webapp); err != nil {
		t.Fatal(err)
	}
	webapp.Spec.Replicas = 5
	webapp.Spec.Image = "nginxinc/nginx-unprivileged:1.31-alpine"
	webapp.Spec.Port = 9090
	webapp.Spec.Env = []appsv1alpha1.EnvVar{{Name: "LOG_LEVEL", Value: "debug"}}
	if err := r.Update(ctx, webapp); err != nil {
		t.Fatal(err)
	}
	reconcileOnce(t, r)

	dep := &appsv1.Deployment{}
	if err := r.Get(ctx, testKey, dep); err != nil {
		t.Fatal(err)
	}
	c := dep.Spec.Template.Spec.Containers[0]
	if *dep.Spec.Replicas != 5 || c.Image != webapp.Spec.Image || c.Ports[0].ContainerPort != 9090 ||
		len(c.Env) != 1 || c.Env[0].Name != "LOG_LEVEL" {
		t.Errorf("deployment not updated: replicas=%d image=%s port=%d env=%+v", *dep.Spec.Replicas, c.Image, c.Ports[0].ContainerPort, c.Env)
	}
	svc := &corev1.Service{}
	if err := r.Get(ctx, testKey, svc); err != nil {
		t.Fatal(err)
	}
	if svc.Spec.Ports[0].Port != 9090 || svc.Spec.Ports[0].TargetPort.IntValue() != 9090 {
		t.Errorf("service port not updated: %+v", svc.Spec.Ports[0])
	}
}

func TestStatusFollowsDeployment(t *testing.T) {
	r := newReconciler(t, sampleWebApp())
	reconcileOnce(t, r)
	ctx := context.Background()

	webapp := &appsv1alpha1.WebApp{}
	if err := r.Get(ctx, testKey, webapp); err != nil {
		t.Fatal(err)
	}
	if webapp.Status.Phase != phasePending {
		t.Errorf("phase = %q, want %q before pods are available", webapp.Status.Phase, phasePending)
	}

	dep := &appsv1.Deployment{}
	if err := r.Get(ctx, testKey, dep); err != nil {
		t.Fatal(err)
	}
	dep.Status.AvailableReplicas = 3
	if err := r.Status().Update(ctx, dep); err != nil {
		t.Fatal(err)
	}
	reconcileOnce(t, r)

	if err := r.Get(ctx, testKey, webapp); err != nil {
		t.Fatal(err)
	}
	if webapp.Status.Phase != phaseRunning || webapp.Status.AvailableReplicas != 3 {
		t.Errorf("status = %+v, want Running/3", webapp.Status)
	}
}

func TestReconcileMissingWebAppIsNotAnError(t *testing.T) {
	r := newReconciler(t)
	reconcileOnce(t, r)
}
