#!/usr/bin/env bash
# Prove the operator (l4 CRD + RBAC + l5 controller) and the admission webhook (l-max) work on a real cluster.
# Expects images already loaded into the cluster:  webapp-operator:dev  and  webapp-webhook:dev
# (CI builds them from the Dockerfiles and runs `kind load docker-image`).
# Usage: bash ci/kind-smoke-operator-and-webhook.sh   (kubectl must point at a throw-away cluster)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="${ROOT}/kubernetes"
NS=demo

dump() {
  echo "::group::cluster state"
  kubectl get all,webapps -n "${NS}" -o wide || true
  kubectl describe webapps -n "${NS}" || true
  kubectl logs -n "${NS}" deploy/webapp-operator --tail=100 || true
  kubectl logs -n "${NS}" deploy/webapp-webhook --tail=50 || true
  echo "::endgroup::"
}
on_exit() {
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then dump; fi
  exit "${rc}"
}
trap on_exit EXIT

# phase_of <name>: print .status.phase of a WebApp
phase_of() { kubectl -n "${NS}" get webapp "$1" -o jsonpath='{.status.phase}'; }

echo "== l4: CRD, operator RBAC and Deployment"
kubectl apply -f "${K8S}/l1-pods-services/namespace-demo-environment-isolation.yaml"
kubectl apply -f "${K8S}/l4-operators-crds/crd-webapp-custom-resource-definition.yaml"
kubectl wait --for=condition=Established crd/webapps.apps.example.com --timeout=60s
kubectl apply -f "${K8S}/l4-operators-crds/operator-controller-deployment-with-rbac.yaml"
kubectl -n "${NS}" rollout status deployment/webapp-operator --timeout=180s

echo "== l5: the controller reconciles a sample WebApp"
kubectl apply -f "${K8S}/l4-operators-crds/cr-webapp-instance-example.yaml"
kubectl -n "${NS}" wait deployment/my-webapp --for=condition=Available --timeout=180s
kubectl -n "${NS}" wait webapp/my-webapp --for=jsonpath='{.status.phase}'=Running --timeout=120s
kubectl -n "${NS}" get webapp my-webapp
test "$(kubectl -n "${NS}" get deploy my-webapp -o jsonpath='{.spec.replicas}')" = 3
test "$(kubectl -n "${NS}" get svc my-webapp -o jsonpath='{.spec.ports[0].port}')" = 8080
test "$(kubectl -n "${NS}" get webapp my-webapp -o jsonpath='{.status.availableReplicas}')" = 3
test "$(kubectl -n "${NS}" get deploy my-webapp -o jsonpath='{.spec.template.spec.containers[0].env[0].name}')" = APP_ENV
kubectl -n "${NS}" get deploy my-webapp -o jsonpath='{.metadata.ownerReferences[0].kind}' | grep -qx WebApp

echo "== l5: spec changes propagate (replicas, env)"
kubectl -n "${NS}" patch webapp my-webapp --type=merge \
  -p '{"spec":{"replicas":2,"env":[{"name":"LOG_LEVEL","value":"debug"}]}}'
kubectl -n "${NS}" wait deployment/my-webapp --for=jsonpath='{.spec.replicas}'=2 --timeout=60s
kubectl -n "${NS}" wait deployment/my-webapp --for=jsonpath='{.spec.template.spec.containers[0].env[0].name}'=LOG_LEVEL --timeout=60s
kubectl -n "${NS}" wait webapp/my-webapp --for=jsonpath='{.status.availableReplicas}'=2 --timeout=120s

echo "== l5: schema validation by the CRD (replicas above maximum is refused)"
if kubectl -n "${NS}" patch webapp my-webapp --type=merge -p '{"spec":{"replicas":500}}' 2>/dev/null; then
  echo "replicas=500 should have been rejected by the CRD schema"; exit 1
fi

echo "== l-max: admission webhook"
bash "${K8S}/l-max-admission-webhook/gen-webhook-certs.sh"
kubectl apply -f "${K8S}/l-max-admission-webhook/webhook-deployment-and-service.yaml"
kubectl -n "${NS}" rollout status deployment/webapp-webhook --timeout=180s

# Validating webhook: an untagged / :latest image is refused with the webhook's message.
if out="$(kubectl -n "${NS}" apply -f - 2>&1 <<'EOF'
apiVersion: apps.example.com/v1alpha1
kind: WebApp
metadata:
  name: bad-latest
spec:
  image: nginx:latest
  replicas: 1
EOF
)"; then
  echo "bad-latest should have been rejected"; exit 1
fi
echo "${out}"
echo "${out}" | grep -q "must have an explicit version tag"
if kubectl -n "${NS}" get webapp bad-latest >/dev/null 2>&1; then
  echo "bad-latest must not exist"; exit 1
fi

# Mutating webhook: a valid WebApp is accepted and gets the managed-by label.
kubectl -n "${NS}" apply -f - <<'EOF'
apiVersion: apps.example.com/v1alpha1
kind: WebApp
metadata:
  name: good-tagged
spec:
  image: nginxinc/nginx-unprivileged:1.30.6-alpine
  replicas: 1
  port: 8080
EOF
test "$(kubectl -n "${NS}" get webapp good-tagged -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" = webapp-operator
# CRD defaulting (port is optional) still applies before the webhooks run.
kubectl -n "${NS}" wait webapp/good-tagged --for=jsonpath='{.status.phase}'=Running --timeout=180s

# Updating an existing object goes through the webhook too.
if kubectl -n "${NS}" patch webapp good-tagged --type=merge -p '{"spec":{"image":"nginx"}}' 2>/dev/null; then
  echo "updating to an untagged image should have been rejected"; exit 1
fi

echo "== cleanup: deleting a WebApp garbage-collects its children"
kubectl -n "${NS}" delete webapp good-tagged my-webapp --wait=true
kubectl -n "${NS}" wait deployment/my-webapp --for=delete --timeout=60s
kubectl -n "${NS}" wait service/my-webapp --for=delete --timeout=60s

echo "Operator and webhook verified on a live cluster."
