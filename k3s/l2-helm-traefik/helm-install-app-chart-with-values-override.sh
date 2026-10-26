#!/usr/bin/env bash
# L2: K3s — Helm Chart Install with Values Override
# Helm is the package manager for Kubernetes. Charts bundle K8s manifests + templating.
# K3s does NOT ship the Helm CLI (it ships a Helm *controller* for HelmChart CRs) — install it separately.
# This script installs Helm 4, then deploys the podinfo demo chart with a values file plus a --set override.
#
# Why podinfo and not a Bitnami chart: Bitnami stopped publishing its free container images to Docker Hub
# in 2025 (older tags moved to the unmaintained bitnamilegacy namespace), so Bitnami charts fail with
# ImagePullBackOff. podinfo is a maintained demo app whose image lives on ghcr.io.
#
# Prerequisites:
#   - K3s running (from l1-install-basic)
#   - kubectl configured (~/.kube/config)
#   - Internet access to download Helm and the chart (OCI registry ghcr.io)
#
# Usage: bash helm-install-app-chart-with-values-override.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_VERSION="${HELM_VERSION:-v4.3.1}"
APP_NAMESPACE="${APP_NAMESPACE:-demo}"
APP_RELEASE="${APP_RELEASE:-my-app}"
APP_CHART="${APP_CHART:-oci://ghcr.io/stefanprodan/charts/podinfo}"
APP_CHART_VERSION="${APP_CHART_VERSION:-6.15.0}"    # Pin chart version for reproducibility

# ── Install Helm CLI ───────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  echo "[INFO] Installing Helm ${HELM_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | \
    DESIRED_VERSION="${HELM_VERSION}" bash
else
  echo "[INFO] Helm already installed: $(helm version --short)"
fi

# ── Deploy app chart with values override ────────────────────────────────────
# Helm 4 flag changes versus Helm 3: --atomic became --rollback-on-failure, and --wait takes a
# strategy (watcher = wait on live object status, the new default for waiting).
echo "[INFO] Installing ${APP_CHART} ${APP_CHART_VERSION} as release '${APP_RELEASE}'..."

# Precedence: chart defaults < -f values file < --set. Here --set raises replicaCount above the file.
helm upgrade --install "${APP_RELEASE}" "${APP_CHART}" \
  --namespace "${APP_NAMESPACE}" \
  --create-namespace \
  --version "${APP_CHART_VERSION}" \
  --values "${HERE}/podinfo-values-override.yaml" \
  --set replicaCount=2 \
  --rollback-on-failure \
  --wait=watcher \
  --timeout=180s

echo ""
echo "[SUCCESS] Chart installed:"
helm list -n "${APP_NAMESPACE}"
echo ""
kubectl get pods,svc -n "${APP_NAMESPACE}"
echo ""
echo "Next: kubectl apply -f ${HERE}/traefik-ingressroute-host-tls-middleware.yaml"
