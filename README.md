# Container Orchestration

Progressive labs for Kubernetes, K3s, and Nomad — covering cluster setup, workload scheduling, operators, and service mesh integration.

## Tools Covered

| Tool | Purpose |
|------|---------|
| **Kubernetes** | Full-featured container orchestration (production standard) |
| **K3s** | Lightweight Kubernetes distribution for edge/homelab |
| **Nomad** | HashiCorp workload scheduler (containers + non-containers) |

## Skill Levels

| Level | Description |
|-------|-------------|
| L1 | Pods, Services, basic deployments |
| L2 | Deployments, ConfigMaps, Secrets |
| L3 | Ingress, PersistentStorage, RBAC |
| L4 | Operators, CRDs, auto-upgrade |
| L5 | Custom controllers |
| L-max | Admission webhooks, embedded registry, parameterized dispatch |

## Prerequisites

- `kubectl` >= 1.28, `helm` >= 3.12
- A running cluster: minikube / kind / K3s / cloud provider
- For K3s labs: Linux VM or bare metal (arm64/amd64)
- For Nomad labs: `nomad` binary >= 1.7, `consul` optional for service mesh

## Quick Start

```bash
# Kubernetes — pods and services
kubectl apply -f kubernetes/l1-pods-services/

# K3s — single-node install
curl -sfL https://get.k3s.io | sh -
kubectl get nodes

# K3s with Helm + Traefik
cd k3s/l2-helm-traefik
helm upgrade --install traefik traefik/traefik -f values.yaml

# Nomad — basic job
cd nomad/l1-job-spec-basic
nomad job run example.nomad.hcl
```

## Directory Structure

```
container-orchestration/
├── kubernetes/
│   ├── l1-pods-services/
│   ├── l2-deployments-configmaps-secrets/
│   ├── l3-ingress-storage-rbac/
│   ├── l4-operators-crds/
│   ├── l5-custom-controller/
│   └── l-max-admission-webhook/
├── k3s/
│   ├── l1-install-basic/
│   ├── l2-helm-traefik/
│   ├── l3-ha-cluster/
│   ├── l4-auto-upgrade-backup/
│   └── l-max-embedded-registry/
└── nomad/
    ├── l1-job-spec-basic/
    ├── l2-multi-task-constraints/
    ├── l3-service-mesh-consul/
    └── l-max-parameterized-dispatch/
```

## Usage

- **Kubernetes**: Apply manifests with `kubectl apply -f <dir>/`. Each level builds on the previous.
- **K3s**: Follow install scripts, then layer on Helm charts and HA config.
- **Nomad**: Run `.nomad.hcl` job specs with `nomad job run`. Consul integration required for L3.
