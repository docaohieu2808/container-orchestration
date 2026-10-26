#!/usr/bin/env bash
# Apply the kubernetes/l1 .. l3 manifests to the current cluster (CI: a kind cluster) and prove they work:
# the objects are accepted by a real API server, the workloads roll out, the Service answers, and the
# PVC binds. Usage: bash ci/kind-smoke-kubernetes-l1-l3.sh   (kubectl must point at a throw-away cluster)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="${ROOT}/kubernetes"
NS=demo

dump() {
  echo "::group::cluster state"
  kubectl get all,cm,secret,pvc,ingress,networkpolicy,hpa -n "${NS}" -o wide || true
  kubectl describe pods -n "${NS}" || true
  echo "::endgroup::"
}
on_exit() {
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then dump; fi
  exit "${rc}"
}
trap on_exit EXIT

echo "== l1: namespace, pod, services"
kubectl apply -f "${K8S}/l1-pods-services/namespace-demo-environment-isolation.yaml"
kubectl apply -f "${K8S}/l1-pods-services/"
kubectl -n "${NS}" wait pod/nginx-basic --for=condition=Ready --timeout=180s

# The three Services select app=nginx,tier=web, which the Pod carries. Prove ClusterIP routing from inside.
kubectl -n "${NS}" get endpoints nginx-clusterip nginx-nodeport -o wide
kubectl -n "${NS}" run curl-l1 --rm -i --restart=Never --image=busybox:1.37 --quiet -- \
  wget -qO- -T 5 http://nginx-clusterip.demo.svc/ | grep -q "Welcome to nginx"

echo "== l2: configmap, secret, quota, deployment, hpa"
kubectl apply -f "${K8S}/l2-deployments-configmaps-secrets/"
kubectl -n "${NS}" rollout status deployment/nginx-deployment --timeout=180s
# The ConfigMap is mounted as a file: nginx serves /health from it (the default image config has no /health).
kubectl -n "${NS}" run curl-l2 --rm -i --restart=Never --image=busybox:1.37 --quiet -- \
  wget -qO- -T 5 http://nginx-clusterip.demo.svc/health | grep -q OK
kubectl -n "${NS}" get hpa nginx-hpa
kubectl -n "${NS}" describe resourcequota demo-namespace-quota

echo "== l3: storage, rbac, ingress, network policy"
# kind ships its own default StorageClass backed by the same provisioner; keep one default only.
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class- --overwrite || true
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/storageclass-local-path-provisioner-k3s.yaml"
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/persistent-volume-claim-standard-storage-request.yaml"
# WaitForFirstConsumer: the PVC binds only once a Pod uses it.
kubectl -n "${NS}" apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pvc-consumer
spec:
  containers:
    - name: c
      image: busybox:1.37
      command: ["sh", "-c", "echo ok > /data/probe && sleep 3600"]
      volumeMounts:
        - name: d
          mountPath: /data
  volumes:
    - name: d
      persistentVolumeClaim:
        claimName: app-data-pvc
EOF
kubectl -n "${NS}" wait pvc/app-data-pvc --for=jsonpath='{.status.phase}'=Bound --timeout=180s
kubectl -n "${NS}" wait pod/pvc-consumer --for=condition=Ready --timeout=120s

kubectl apply -f "${K8S}/l3-ingress-storage-rbac/rbac-developer-role-namespace-scoped.yaml"
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/rbac-readonly-clusterrole-cluster-wide-view.yaml"
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/ingress-traefik-host-path-tls-rules.yaml"
# RBAC does what its comments say: the developer can read pods but not secrets.
kubectl auth can-i list pods -n "${NS}" --as=alice --quiet
if kubectl auth can-i get secrets -n "${NS}" --as=alice --quiet; then
  echo "alice must not be able to read secrets"; exit 1
fi
kubectl auth can-i list pods --all-namespaces --as=system:serviceaccount:monitoring:monitoring-agent --quiet

# Apply the NetworkPolicies last: default-deny also cuts the egress the probes above used.
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/network-policy-deny-all-allow-web-ingress-only.yaml"
kubectl -n "${NS}" get networkpolicy

echo "All l1-l3 manifests applied and verified."
