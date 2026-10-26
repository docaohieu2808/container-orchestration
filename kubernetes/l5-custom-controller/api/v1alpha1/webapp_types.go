package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// EnvVar is a plain name/value environment variable for the web application container.
type EnvVar struct {
	// Name of the variable.
	Name string `json:"name"`
	// Value of the variable.
	// +optional
	Value string `json:"value,omitempty"`
}

// WebAppSpec is the desired state of a WebApp.
type WebAppSpec struct {
	// Image is the container image for the web application (must carry an explicit tag).
	Image string `json:"image"`

	// Replicas is the number of desired Pod replicas.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=50
	Replicas int32 `json:"replicas"`

	// Port is the container port to expose through the Service.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +kubebuilder:default=80
	// +optional
	Port int32 `json:"port,omitempty"`

	// Env is passed to the application container.
	// +optional
	Env []EnvVar `json:"env,omitempty"`
}

// WebAppStatus is the observed state of a WebApp.
type WebAppStatus struct {
	// AvailableReplicas is the number of Pods currently available.
	// +optional
	AvailableReplicas int32 `json:"availableReplicas,omitempty"`

	// Phase is the current lifecycle phase.
	// +kubebuilder:validation:Enum=Pending;Running;Failed
	// +optional
	Phase string `json:"phase,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=wa
// +kubebuilder:printcolumn:name="Image",type=string,JSONPath=`.spec.image`
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Available",type=integer,JSONPath=`.status.availableReplicas`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// WebApp is the Schema for the webapps API.
type WebApp struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebAppSpec   `json:"spec,omitempty"`
	Status WebAppStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WebAppList contains a list of WebApp.
type WebAppList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebApp `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebApp{}, &WebAppList{})
}
