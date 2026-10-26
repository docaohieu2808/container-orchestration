#!/usr/bin/env bash
# Apply the kubernetes/l1 .. l3 manifests to the current cluster (CI: a kind cluster) and prove they work:
# the objects are accepted by a real API server, the workloads roll out, the Service answers, and the
# PVC binds. Usage: bash ci/kind-smoke-kubernetes-l1-l3.sh   (kubectl must point at a throw-away cluster)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="${ROOT}/kubernetes"
NS=demo
METRICS_SERVER_VERSION="v0.9.0"   # kubernetes-sigs/metrics-server release (kind needs --kubelet-insecure-tls)
TRAEFIK_CHART_VERSION="42.1.3"    # traefik/traefik Helm chart (the Ingress controller K3s ships)

dump() {
  echo "::group::cluster state"
  kubectl get all,cm,secret,pvc,ingress,networkpolicy,hpa -n "${NS}" -o wide || true
  kubectl describe pods -n "${NS}" || true
  kubectl get pods -n kube-system -o wide || true
  kubectl describe pods -n kube-system -l app.kubernetes.io/name=traefik || true
  kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50 || true
  echo "::endgroup::"
}
pf_pid=""
on_exit() {
  local rc=$?
  if [[ -n "${pf_pid}" ]]; then kill "${pf_pid}" 2>/dev/null || true; fi
  if [[ ${rc} -ne 0 ]]; then dump; fi
  exit "${rc}"
}
trap on_exit EXIT

# in_cluster_get <url>: GET from a throw-away busybox pod and print the body. The result is captured by the
# caller rather than piped into `grep -q`, which would close the pipe early and trip pipefail (SIGPIPE).
in_cluster_get() {
  kubectl -n "${NS}" run "curl-$RANDOM" --rm -i --restart=Never --image=busybox:1.37 --quiet -- wget -qO- -T 5 "$1"
}

echo "== l1: namespace, pod, services"
kubectl apply -f "${K8S}/l1-pods-services/namespace-demo-environment-isolation.yaml"
kubectl apply -f "${K8S}/l1-pods-services/"
kubectl -n "${NS}" wait pod/nginx-basic --for=condition=Ready --timeout=180s

# The three Services select app=nginx,tier=web, which the Pod carries. Prove ClusterIP routing from inside.
kubectl -n "${NS}" get endpoints nginx-clusterip nginx-nodeport -o wide
body="$(in_cluster_get http://nginx-clusterip.demo.svc/)"
grep -q "Welcome to nginx" <<<"${body}"

# The Pod and the Deployment's Pods share the labels the Services select. The Pod has the stock nginx config
# (no /health), so remove it before l2 or half of the requests below would hit it.
kubectl -n "${NS}" delete pod nginx-basic --wait=true

echo "== l2: configmap, secret, quota, deployment, hpa"
kubectl apply -f "${K8S}/l2-deployments-configmaps-secrets/"
kubectl -n "${NS}" rollout status deployment/nginx-deployment --timeout=180s
# The ConfigMap is mounted as a file: nginx serves /health from it (the default image config has no /health).
body="$(in_cluster_get http://nginx-clusterip.demo.svc/health)"
grep -q OK <<<"${body}"

# HPA: install metrics-server and require the HPA to read real CPU and memory numbers (not <unknown>).
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
hpa_metrics=""
for _ in $(seq 1 30); do
  hpa_metrics="$(kubectl -n "${NS}" get hpa nginx-hpa -o jsonpath='{range .status.currentMetrics[*]}{.resource.name}={.resource.current.averageUtilization} {end}')"
  if [[ "${hpa_metrics}" == *cpu=[0-9]* && "${hpa_metrics}" == *memory=[0-9]* ]]; then break; fi
  sleep 10
done
echo "HPA current metrics: ${hpa_metrics}"
[[ "${hpa_metrics}" == *cpu=[0-9]* && "${hpa_metrics}" == *memory=[0-9]* ]] || { echo "HPA never read CPU and memory"; exit 1; }
[[ "$(kubectl -n "${NS}" get hpa nginx-hpa -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}')" == True ]]
# minReplicas is 2: the HPA must hold the Deployment at two or more ready replicas.
[[ "$(kubectl -n "${NS}" get deployment nginx-deployment -o jsonpath='{.status.readyReplicas}')" -ge 2 ]]

# ResourceQuota: usage is tracked and an object over the hard limit (configmaps: 20) is rejected.
[[ "$(kubectl -n "${NS}" get resourcequota demo-namespace-quota -o jsonpath='{.status.used.pods}')" -ge 1 ]]
quota_err=""
for i in $(seq 1 25); do
  if ! out="$(kubectl -n "${NS}" create configmap "quota-probe-${i}" --from-literal=k=v 2>&1)"; then quota_err="${out}"; break; fi
done
echo "quota rejection: ${quota_err}"
grep -q "exceeded quota: demo-namespace-quota" <<<"${quota_err}"
for i in $(seq 1 25); do kubectl -n "${NS}" delete configmap "quota-probe-${i}" --ignore-not-found >/dev/null; done

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
# Ingress: install Traefik (K3s ships it; kind does not), give the host a TLS Secret, and curl through the controller.
tmp="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "${tmp}/tls.key" -out "${tmp}/tls.crt" \
  -subj "/CN=demo.example.com" -addext "subjectAltName=DNS:demo.example.com" 2>/dev/null
kubectl -n "${NS}" create secret tls demo-tls-secret --cert="${tmp}/tls.crt" --key="${tmp}/tls.key"
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm install traefik traefik/traefik --version "${TRAEFIK_CHART_VERSION}" --namespace kube-system \
  --set service.type=ClusterIP --wait --timeout 4m
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/ingress-traefik-host-path-tls-rules.yaml"

kubectl -n kube-system port-forward deployment/traefik 8443:8443 >/dev/null 2>&1 &
pf_pid=$!

# through_traefik <path>: HTTPS GET for demo.example.com via the port-forwarded Traefik websecure entrypoint,
# retrying while Traefik picks up the Ingress. Prints the body; the served certificate is checked separately.
through_traefik() {
  local out
  for _ in $(seq 1 30); do
    if out="$(curl -sS --fail --max-time 5 --cacert "${tmp}/tls.crt" --resolve demo.example.com:8443:127.0.0.1 "https://demo.example.com:8443$1" 2>/dev/null)"; then
      printf '%s' "${out}"; return 0
    fi
    sleep 2
  done
  return 1
}
body="$(through_traefik /health)"
grep -q OK <<<"${body}"
# TLS terminates at Traefik with the Secret's certificate (--cacert pins it to ours, so a default cert would fail).
# /api routes to api-service, which this lab does not deploy: Traefik answers 503 or 404 rather than the nginx page.
api_code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${tmp}/tls.crt" --resolve demo.example.com:8443:127.0.0.1 https://demo.example.com:8443/api)"
[[ "${api_code}" == 503 || "${api_code}" == 404 ]]

# RBAC does what its comments say: the developer can read pods but not secrets.
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/rbac-developer-role-namespace-scoped.yaml"
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/rbac-readonly-clusterrole-cluster-wide-view.yaml"
kubectl auth can-i list pods -n "${NS}" --as=alice --quiet
if kubectl auth can-i get secrets -n "${NS}" --as=alice --quiet; then
  echo "alice must not be able to read secrets"; exit 1
fi
kubectl auth can-i list pods --all-namespaces --as=system:serviceaccount:monitoring:monitoring-agent --quiet

# NetworkPolicy: applied last because default-deny also cuts the egress the probes above used. The cluster CNI must
# enforce policy. Prove it by behaviour: a pod in the namespace is cut off from the web pods (timeout) while Traefik,
# the one allowed source, still reaches them on 8080.
web_ip="$(kubectl -n "${NS}" get pods -l tier=web -o jsonpath='{.items[0].status.podIP}')"
kubectl apply -f "${K8S}/l3-ingress-storage-rbac/network-policy-deny-all-allow-web-ingress-only.yaml"
kubectl -n "${NS}" get networkpolicy
sleep 5
# Probes run from kube-system, where egress is open, so only the ingress rules on the web pods decide the result.
# probe <port> <labels>: prints connected (port open), refused (reached the pod, nothing listens) or timeout (dropped).
probe() {
  kubectl -n kube-system run "np-$RANDOM" --rm -i --restart=Never --quiet --labels="$2" --image=busybox:1.37 -- sh -c \
    "s=\$(date +%s); if nc -z -w 5 ${web_ip} $1; then echo connected; elif [ \$((\$(date +%s)-s)) -ge 4 ]; then echo timeout; else echo refused; fi" \
    2>/dev/null | tail -n1
}
# Denied: a pod that is not Traefik times out on the web port.
[[ "$(probe 8080 app=intruder)" == timeout ]] || { echo "NetworkPolicy did not block a non-Traefik pod"; exit 1; }
# Allowed: a Traefik-labelled pod in kube-system connects.
[[ "$(probe 8080 app.kubernetes.io/name=traefik)" == connected ]] || { echo "NetworkPolicy blocked the allowed source"; exit 1; }
# Only port 8080 is open, even for the allowed source: port 80 is dropped (timeout), not refused.
[[ "$(probe 80 app.kubernetes.io/name=traefik)" == timeout ]] || { echo "NetworkPolicy allowed a port it should not"; exit 1; }
# The real controller still serves the app through the policy.
body="$(through_traefik /health)"
grep -q OK <<<"${body}"

echo "All l1-l3 manifests applied and verified."
