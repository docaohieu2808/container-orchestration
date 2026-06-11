# container-orchestration

Leveled reference implementations for Kubernetes, K3s, and Nomad — from basic pod specs to custom controllers, admission webhooks, HA cluster setup, and service mesh. All manifests use current (non-deprecated) APIs.

## Structure

```
container-orchestration/
├── kubernetes/
│   ├── l1-pods-services/             # Pod, Service (ClusterIP/NodePort/LoadBalancer), Namespace
│   ├── l2-deployments-configmaps-secrets/  # Deployment, ConfigMap, Secret, HPA, ResourceQuota
│   ├── l3-ingress-storage-rbac/      # Ingress, NetworkPolicy, PVC, RBAC roles + bindings
│   ├── l4-operators-crds/            # CRD definition, CR instance, operator Deployment + RBAC
│   ├── l5-custom-controller/         # Go controller-runtime reconcile loop + main entrypoint
│   └── l-max-admission-webhook/      # ValidatingWebhookConfiguration + Go webhook server
├── k3s/
│   ├── l1-install-basic/             # Single-node K3s install script (Oracle/ARM)
│   ├── l2-helm-traefik/              # Helm chart install + Traefik IngressRoute with TLS
│   ├── l3-ha-cluster/                # 3-node HA embedded etcd setup
│   ├── l4-auto-upgrade-backup/       # system-upgrade-controller plan + etcd S3 backup CronJob
│   └── l-max-embedded-registry/      # containerd registry mirror config (Harbor, DockerHub pull-through)
└── nomad/
    ├── l1-job-spec-basic/            # Nginx Docker driver job
    ├── l2-multi-task-constraints/    # Multi-task group with volume constraints
    ├── l3-service-mesh-consul/       # Consul Connect sidecar service mesh
    └── l-max-parameterized-dispatch/ # Parameterized batch job dispatch
```

## API versions used (all current)

| Resource | API version |
|---|---|
| Deployment / DaemonSet / StatefulSet | `apps/v1` |
| Ingress | `networking.k8s.io/v1` |
| HPA | `autoscaling/v2` |
| ClusterRole / RoleBinding | `rbac.authorization.k8s.io/v1` |
| ValidatingWebhookConfiguration | `admissionregistration.k8s.io/v1` |
| CronJob | `batch/v1` |
| CRD | `apiextensions.k8s.io/v1` |

## Quick lab: K3s single-node + ArgoCD

```bash
# Install K3s
bash k3s/l1-install-basic/k3s-install-single-node-oracle-server.sh

# Install ArgoCD + bootstrap from argocd-apps repo
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f /path/to/argocd-apps/apps/root-app-of-apps-entry-point.yml
```

## Custom controller (l5)

The Go controller in `kubernetes/l5-custom-controller/` uses `controller-runtime` to reconcile a `WebApp` CRD. It demonstrates the standard operator pattern: watch CRD → reconcile desired state → update status.

Build:
```bash
cd kubernetes/l5-custom-controller
go build -o manager .
```

## Admission webhook (l-max)

`kubernetes/l-max-admission-webhook/` implements both a `ValidatingWebhookConfiguration` and a `MutatingWebhookConfiguration` with a Go HTTPS server. Requires a TLS cert signed by the cluster CA (or injected via cert-manager).

## K3s registry mirror

`k3s/l-max-embedded-registry/k3s-registries-mirror-config.yaml` configures containerd pull-through cache for Docker Hub, GCR, and GHCR, and TLS auth for a private Harbor instance. Deploy to `/etc/rancher/k3s/registries.yaml` on every node, then `systemctl restart k3s`.

All passwords in this file are **placeholders** — replace before deploying.
