#!/usr/bin/env bash
# L1: K3s — Single Node Install
# K3s is a lightweight, CNCF-certified Kubernetes distribution by Rancher.
# Single binary, bundles: containerd, CNI (Flannel), CoreDNS, Traefik ingress,
# local-path-provisioner, ServiceLB (Klipper) LoadBalancer, metrics-server, network policy controller.
#
# This script installs a K3s server (control-plane + worker) on one Linux host (amd64 or arm64,
# e.g. a free-tier Oracle ARM instance).
#
# Prerequisites:
#   - A systemd Linux host (Ubuntu 22.04+ or Oracle Linux), root or sudo
#   - Inbound ports open: 6443 (K8s API), 80/443 (Traefik), 10250 (kubelet)
#
# Usage: sudo bash k3s-install-single-node.sh
# Optional environment:
#   K3S_VERSION  release to install (default below: current "stable" channel at the time of writing)
#   NODE_IP      private IP to advertise (and add to the API certificate); autodetected when empty
#   KUBECONFIG_USER_HOME   where to copy the kubeconfig for the invoking user (default: $HOME)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"   # Pin a release for reproducibility
NODE_IP="${NODE_IP:-}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
KUBECONFIG_USER_HOME="${KUBECONFIG_USER_HOME:-${HOME}}"

# ── Pre-flight checks ──────────────────────────────────────────────────────────
echo "[INFO] Checking prerequisites..."
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (sudo)"
  exit 1
fi

# Swap does not need to be disabled: K3s starts with kubelet --fail-swap-on=false.

# Load required kernel modules
modprobe overlay
modprobe br_netfilter

# Configure sysctl for Kubernetes networking
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF2
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF2
sysctl --system >/dev/null
echo "[INFO] Kernel parameters configured"

# ── Install K3s ────────────────────────────────────────────────────────────────
echo "[INFO] Installing K3s ${K3S_VERSION}..."

# Server flags:
#   --write-kubeconfig-mode 644: allow non-root kubectl access
#   --node-ip / --tls-san:       only when NODE_IP is set (advertise the private IP, allow remote kubectl)
# Traefik, ServiceLB (Klipper), local-path storage and metrics-server stay enabled: the later
# levels and kubernetes/l1-l3 rely on them (add --disable=traefik to bring your own ingress).
EXEC_ARGS=(server --write-kubeconfig-mode=644)
if [[ -n "${NODE_IP}" ]]; then
  EXEC_ARGS+=("--node-ip=${NODE_IP}" "--tls-san=${NODE_IP}")
fi

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="${EXEC_ARGS[*]}" \
  sh -

# ── Post-install ───────────────────────────────────────────────────────────────
echo "[INFO] Waiting for K3s to be ready..."
until [[ -s "${KUBECONFIG_PATH}" ]] && kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; do
  sleep 2
done

# Verify node is Ready
kubectl --kubeconfig="${KUBECONFIG_PATH}" wait node \
  --all --for=condition=Ready --timeout=180s

# Export kubeconfig for the invoking user
mkdir -p "${KUBECONFIG_USER_HOME}/.kube"
cp "${KUBECONFIG_PATH}" "${KUBECONFIG_USER_HOME}/.kube/config"
chmod 600 "${KUBECONFIG_USER_HOME}/.kube/config"
if [[ -n "${SUDO_UID:-}" ]]; then
  chown -R "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${KUBECONFIG_USER_HOME}/.kube"
fi

# ── Print cluster info ─────────────────────────────────────────────────────────
echo ""
echo "[SUCCESS] K3s ${K3S_VERSION} installed successfully!"
echo ""
kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes -o wide
echo ""
echo "Join token for worker nodes is in /var/lib/rancher/k3s/server/node-token (root only)."
echo "To add a worker node, run on the worker:"
echo "  curl -sfL https://get.k3s.io | K3S_URL=https://<this-node-ip>:6443 K3S_TOKEN=<token> sh -"
echo ""
echo "Kubeconfig copied to: ${KUBECONFIG_USER_HOME}/.kube/config"
