#!/usr/bin/env bash
# L1: K3s — Single Node Install on Oracle Server (10.10.0.5)
# K3s is a lightweight, CNCF-certified Kubernetes distribution by Rancher.
# Single binary (~70MB), bundles: containerd, CNI (Flannel), CoreDNS,
# Traefik ingress, local-path-provisioner, Klipper LoadBalancer, metrics-server.
#
# This script installs K3s server (control-plane + worker) on a single node.
# Managed via Rancher (UI) after install — ensure Rancher agent is registered.
#
# Prerequisites:
#   - Oracle Linux / Ubuntu 22.04 on amd64
#   - Inbound ports open: 6443 (K8s API), 80/443 (Traefik), 10250 (kubelet)
#   - Run as root or with sudo
#
# Usage: sudo bash k3s-install-single-node-oracle-server.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
NODE_IP="10.10.0.5"                    # Oracle server private IP
K3S_VERSION="v1.28.5+k3s1"            # Pin version for reproducibility
K3S_DATA_DIR="/var/lib/rancher/k3s"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

# ── Pre-flight checks ──────────────────────────────────────────────────────────
echo "[INFO] Checking prerequisites..."
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (sudo)"
  exit 1
fi

# Disable swap (Kubernetes requirement)
swapoff -a
sed -i '/swap/d' /etc/fstab
echo "[INFO] Swap disabled"

# Load required kernel modules
modprobe overlay
modprobe br_netfilter

# Configure sysctl for Kubernetes networking
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
echo "[INFO] Kernel parameters configured"

# ── Install K3s ────────────────────────────────────────────────────────────────
echo "[INFO] Installing K3s ${K3S_VERSION}..."

# INSTALL_K3S_EXEC flags:
#   --node-ip: advertise the Oracle private IP
#   --tls-san: add node IP to TLS cert SAN (allows remote kubectl access)
#   --disable traefik: remove if you want to manage Traefik yourself via Helm
#   --write-kubeconfig-mode 644: allow non-root kubectl access
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --node-ip=${NODE_IP} \
    --tls-san=${NODE_IP} \
    --write-kubeconfig-mode=644 \
    --data-dir=${K3S_DATA_DIR} \
    --disable=servicelb \
    --kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log" \
  sh -

# ── Post-install ───────────────────────────────────────────────────────────────
echo "[INFO] Waiting for K3s to be ready..."
sleep 10

# Verify node is Ready
kubectl --kubeconfig=${KUBECONFIG_PATH} wait node \
  --all --for=condition=Ready --timeout=120s

# Export kubeconfig for current user
mkdir -p "${HOME}/.kube"
cp ${KUBECONFIG_PATH} "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"

# ── Print cluster info ─────────────────────────────────────────────────────────
echo ""
echo "[SUCCESS] K3s ${K3S_VERSION} installed successfully!"
echo ""
kubectl get nodes -o wide
echo ""
echo "Node token (for joining worker nodes):"
cat /var/lib/rancher/k3s/server/node-token
echo ""
echo "To add a worker node, run on the worker:"
echo "  curl -sfL https://get.k3s.io | K3S_URL=https://${NODE_IP}:6443 K3S_TOKEN=<token> sh -"
echo ""
echo "Kubeconfig saved to: ${HOME}/.kube/config"
echo "To register with Rancher: import this cluster via Rancher UI -> Cluster Management -> Import"
