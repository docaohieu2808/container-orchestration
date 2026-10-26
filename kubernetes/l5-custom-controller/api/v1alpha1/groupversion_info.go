// Package v1alpha1 contains the API types for the apps.example.com/v1alpha1 group.
//
// The markers below are read by controller-gen (see the Makefile):
//   - object:generate  -> zz_generated.deepcopy.go (DeepCopy methods every runtime.Object needs)
//   - crd              -> the CustomResourceDefinition in kubernetes/l4-operators-crds
//
// +kubebuilder:object:generate=true
// +groupName=apps.example.com
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is the group/version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "apps.example.com", Version: "v1alpha1"}

	// SchemeBuilder collects the types so main() can add them to a runtime.Scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme registers WebApp and WebAppList in a scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)

// Resource returns the fully qualified GroupResource for a plural resource name.
func Resource(resource string) schema.GroupResource {
	return GroupVersion.WithResource(resource).GroupResource()
}
