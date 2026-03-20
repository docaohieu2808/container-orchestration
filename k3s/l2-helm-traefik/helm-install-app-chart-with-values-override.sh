#!/usr/bin/env bash
# L2: K3s — Helm Chart Install with Values Override
# Helm is the package manager for Kubernetes. Charts bundle K8s manifests + templating.
# K3s does NOT ship Helm by default — install it separately (v3 only, no Tiller).
# This script installs the Helm CLI, adds common repos, and deploys a sample app chart.
#
# Prerequisites:
#   - K3s running (from l1-install-basic)
#   - kubectl configured (~/.kube/config)
#   - Internet access to download Helm and charts
#
# Usage: bash helm-install-app-chart-with-values-override.sh

set -euo pipefail

HELM_VERSION="v3.13.3"
APP_NAMESPACE="demo"
APP_RELEASE="my-nginx"
APP_CHART="bitnami/nginx"
APP_CHART_VERSION="15.14.0"    # Pin chart version for reproducibility

# ── Install Helm CLI ───────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  echo "[INFO] Installing Helm ${HELM_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | \
    DESIRED_VERSION="${HELM_VERSION}" bash
else
  echo "[INFO] Helm already installed: $(helm version --short)"
fi

# ── Add Helm repositories ──────────────────────────────────────────────────────
echo "[INFO] Adding Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add traefik https://traefik.github.io/charts
helm repo update
echo "[INFO] Repositories updated"

# ── Create namespace ───────────────────────────────────────────────────────────
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Deploy app chart with values override ────────────────────────────────────
echo "[INFO] Installing ${APP_CHART} as release '${APP_RELEASE}'..."

helm upgrade --install "${APP_RELEASE}" "${APP_CHART}" \
  --namespace "${APP_NAMESPACE}" \
  --version "${APP_CHART_VERSION}" \
  --set replicaCount=2 \
  --set service.type=ClusterIP \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi \
  --set ingress.enabled=true \
  --set ingress.ingressClassName=traefik \
  --set "ingress.hostname=nginx.example.com" \
  --atomic \         # Roll back automatically if install fails
  --timeout=120s \
  --wait

echo ""
echo "[SUCCESS] Chart installed:"
helm list -n "${APP_NAMESPACE}"
echo ""
kubectl get pods,svc,ingress -n "${APP_NAMESPACE}"
