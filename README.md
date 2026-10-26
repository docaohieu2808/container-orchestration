# container-orchestration

[![ci](https://github.com/docaohieu2808/container-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/docaohieu2808/container-orchestration/actions/workflows/ci.yml)

A ladder for learning container orchestration on Kubernetes, k3s and Nomad, from a single Pod to a custom
controller and an admission webhook, an HA cluster and a service mesh. Every level that can run on a
GitHub-hosted runner is run for real by CI on every push and once a week (kind, k3s, `nomad agent -dev`), and
everything else is validated statically, so the files here are known to apply and work on current releases.

Versions verified on 2026-10-26: Kubernetes 1.37, k3s v1.36.5 (stable channel), Helm 4.3.1, Nomad 2.0.7,
controller-runtime 0.25, Go 1.26+, nginx 1.30.

## Level map

| Tier | Kubernetes | k3s | Nomad |
| :-- | :-- | :-- | :-- |
| L1 | [`l1-pods-services`](kubernetes/l1-pods-services): Namespace, Pod, ClusterIP / NodePort / LoadBalancer Services | [`l1-install-basic`](k3s/l1-install-basic): single-node install script | [`l1-job-spec-basic`](nomad/l1-job-spec-basic): nginx job on the Docker driver |
| L2 | [`l2-deployments-configmaps-secrets`](kubernetes/l2-deployments-configmaps-secrets): Deployment, ConfigMap (env + file mount), Secret, HPA, ResourceQuota | [`l2-helm-traefik`](k3s/l2-helm-traefik): Helm 4 chart install with a values override, Traefik IngressRoute + Middleware | [`l2-multi-task-constraints`](nomad/l2-multi-task-constraints): sidecar, constraints, host volume, Vault workload identity |
| L3 | [`l3-ingress-storage-rbac`](kubernetes/l3-ingress-storage-rbac): Ingress (Traefik), NetworkPolicy, PVC + StorageClass, RBAC | [`l3-ha-cluster`](k3s/l3-ha-cluster): 3-server HA with embedded etcd | [`l3-service-mesh-consul`](nomad/l3-service-mesh-consul): Consul Connect mTLS sidecars |
| L4 | [`l4-operators-crds`](kubernetes/l4-operators-crds): CRD, custom resource, operator Deployment + RBAC | [`l4-auto-upgrade-backup`](k3s/l4-auto-upgrade-backup): System Upgrade Controller plans, built-in etcd snapshots to S3 | |
| L5 | [`l5-custom-controller`](kubernetes/l5-custom-controller): Go controller-runtime reconciler for the `WebApp` CRD | | |
| L-max | [`l-max-admission-webhook`](kubernetes/l-max-admission-webhook): mutating + validating webhook (Go) | [`l-max-registry-mirrors`](k3s/l-max-registry-mirrors): `registries.yaml` pull-through mirrors and the embedded Spegel registry | [`l-max-parameterized-dispatch`](nomad/l-max-parameterized-dispatch): parameterized batch job + dispatch |

## What each level needs, and how to run it

Only Docker is needed for the Kubernetes levels (use [kind](https://kind.sigs.k8s.io/)); k3s needs a Linux host;
Nomad l1 and l-max need Docker and the `nomad` binary.

### Kubernetes (kind)

```bash
kind create cluster --name lab
kubectl apply -f kubernetes/l1-pods-services/                  # Namespace "demo" first, then Pod + Services
kubectl apply -f kubernetes/l2-deployments-configmaps-secrets/
kubectl -n demo rollout status deploy/nginx-deployment
```

[`ci/kind-smoke-kubernetes-l1-l3.sh`](ci/kind-smoke-kubernetes-l1-l3.sh) is the whole l1-l3 walkthrough as a script
(it also shows the PVC binding, RBAC `can-i` checks and the NetworkPolicies, applied last because default-deny cuts
egress). The pods use `nginxinc/nginx-unprivileged` (non-root, port 8080) with a restricted-style `securityContext`.
On plain kind the LoadBalancer Service stays `<pending>` (k3s's ServiceLB gives it the node IP); the Ingress object
is accepted but needs an ingress controller (k3s ships Traefik) to route. ingress-nginx was retired in March 2026, so
the Ingress example uses Traefik.

### L4 and L5: operator

The Go types in [`kubernetes/l5-custom-controller/api/v1alpha1`](kubernetes/l5-custom-controller/api/v1alpha1) are the
source of truth: controller-gen generates the DeepCopy code and the CRD in `l4-operators-crds`.

```bash
cd kubernetes/l5-custom-controller
make test                 # fake-client unit tests of the reconciler
make docker-build         # webapp-operator:dev
kind load docker-image webapp-operator:dev --name lab
cd ../l4-operators-crds
kubectl apply -f crd-webapp-custom-resource-definition.yaml -f operator-controller-deployment-with-rbac.yaml
kubectl apply -f cr-webapp-instance-example.yaml
kubectl -n demo get webapps      # PHASE Running, AVAILABLE 3; the operator made a Deployment and a Service
```

After `make generate manifests` (needs only Go) the working tree must be clean: CI fails if the committed generated
code drifts from the types. The controller uses `controllerutil.CreateOrUpdate`, so replicas, image, port and env of the
WebApp all propagate to the children, and `RetryOnConflict` for status writes. controller-runtime 0.15+ replaced the
old manager options (`MetricsBindAddress`, `Port`, `Namespace`) with `Metrics`, `WebhookServer` and
`Cache.DefaultNamespaces`; `main-entrypoint-controller-manager.go` shows the current form.

### L-max: admission webhook

```bash
cd kubernetes/l-max-admission-webhook
docker build -t webapp-webhook:dev . && kind load docker-image webapp-webhook:dev --name lab
bash gen-webhook-certs.sh                       # CA + serving cert with SANs, webhook-tls Secret, WebhookConfigurations with caBundle
kubectl apply -f webhook-deployment-and-service.yaml
```

The validating webhook rejects images without an explicit tag (or `:latest`); the mutating webhook adds the
`app.kubernetes.io/managed-by` label. Only namespaces labelled `webhook-injection=enabled` are intercepted. In a real
cluster let cert-manager issue and rotate the certificate. `ci/kind-smoke-operator-and-webhook.sh` exercises all of it.

### k3s

```bash
sudo bash k3s/l1-install-basic/k3s-install-single-node.sh                 # K3S_VERSION, NODE_IP optional
bash k3s/l2-helm-traefik/helm-install-app-chart-with-values-override.sh   # installs Helm 4, then podinfo
kubectl apply -f k3s/l2-helm-traefik/traefik-ingressroute-host-tls-middleware.yaml
```

- **L2** deploys the maintained `podinfo` chart instead of a Bitnami chart: Bitnami stopped publishing its free
  images to Docker Hub in 2025, so those charts end in ImagePullBackOff. The script uses Helm 4 flag names
  (`--rollback-on-failure` replaces `--atomic`; `--wait=watcher`).
- **L3** needs three hosts: `K3S_TOKEN=... SERVER1_IP=... NODE_ROLE=init sudo -E bash k3s/l3-ha-cluster/...sh`
  on the first, `NODE_ROLE=join` on the others. `DRY_RUN=1` prints the install command without touching the host.
- **L4** installs the System Upgrade Controller (commands in the plan file) and applies the two plans (server first,
  then agents, via the agent plan's `prepare` step). Backups use K3s's built-in snapshots with S3
  upload ([`etcd-snapshot-s3-server-config.yaml`](k3s/l4-auto-upgrade-backup/etcd-snapshot-s3-server-config.yaml))
  rather than a CronJob.
- **L-max**: copy a file to `/etc/rancher/k3s/registries.yaml`. All credentials there are `<placeholders>`.

### Nomad

```bash
sudo nomad agent -dev &                                      # one-node server + client on :4646
nomad job run nomad/l1-job-spec-basic/nginx-web-server-docker-driver.nomad.hcl
nomad service info nginx-web
nomad job run nomad/l-max-parameterized-dispatch/batch-job-parameterized-dispatch.nomad.hcl
echo '{"rows":[1,2,3]}' > input.json
nomad job dispatch -meta REPORT_TYPE=daily -meta OUTPUT_FORMAT=csv batch-report-generator input.json
```

L2 uses Vault with workload identity (the job-level `policies` setting was removed in Nomad 1.10) and L3 needs Consul
with Connect, CNI plugins and a Nomad variable for the Postgres password; their prerequisites are in the job file
headers. Images named `myapp` are placeholders for your own application.

## What CI checks

[`.github/workflows/ci.yml`](.github/workflows/ci.yml), on push, pull request, weekly (Mondays 03:17 UTC) and on demand:

| Job | Checks |
| :-- | :-- |
| `lint` | actionlint, shellcheck, `yamllint --strict`, hadolint on both Dockerfiles, every action pinned to an existing commit SHA |
| `manifests` | `kubeconform -strict` against Kubernetes 1.37 for all Kubernetes/k3s manifests; schemas for WebApp, Traefik and System Upgrade Controller resources are converted from their real CRDs, nothing is skipped |
| `helm` | Helm 4 `lint` + `template` of the l2 chart with the lab values, the output validated by kubeconform, overrides asserted in the rendered YAML |
| `go` | for the controller and the webhook: gofmt, `go mod tidy` clean, `go vet`, `go test -race`, `go build`; controller-gen output matches the committed code and CRD |
| `kind (kubernetes l1-l3)` | applies and rolls out l1-l3 on kind, curls the Services, binds the PVC, checks RBAC |
| `kind (operator + webhook)` | builds both images, loads them into kind, then: CRD established, operator rolls out, a sample WebApp reconciles to Running, spec changes propagate, CRD schema rejects bad input, webhook rejects `:latest` and labels good objects, deleting a WebApp garbage-collects its children |
| `k3s` | runs the l1 and l2 scripts on a real k3s (ServiceLB assigns an IP, Helm 4 installs podinfo with overrides, Traefik IngressRoutes redirect and route), l3 in dry-run, l4 plans server-side validated against the real CRD |
| `nomad` | `nomad fmt -check`, `nomad job validate` on all four jobs, l1 runs on a dev agent and both allocations answer, l-max is dispatched with metadata and a payload |

## Honest limits

- Not run in CI because a runner has no suitable infrastructure: a real 3-node k3s HA cluster, an actual k3s
  upgrade through the System Upgrade Controller, etcd snapshots to S3, registry mirrors (their YAML is linted only),
  Nomad l2 (needs Vault) and l3 (needs Consul + Envoy). These are validated statically.
- The controller and webhook are tested with a fake client / `httptest` and against a live kind cluster, not with
  envtest.
- Pinned versions move: CI runs weekly so a breaking upstream release shows up as a red build, and Dependabot proposes
  action, Go module and Dockerfile bumps.

## License

[MIT](LICENSE)
