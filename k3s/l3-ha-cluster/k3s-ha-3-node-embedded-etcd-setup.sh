#!/usr/bin/env bash
# L3: K3s — 3-Node HA Cluster with Embedded etcd
# K3s supports HA via embedded etcd (Raft consensus) — no external etcd required.
# Minimum 3 server nodes for quorum (tolerates 1 failure).
# Architecture:
#   server-1 (10.10.0.5) — bootstrap node (init cluster)
#   server-2 (10.10.0.6) — joins existing cluster
#   server-3 (10.10.0.7) — joins existing cluster
#
# All 3 nodes run control-plane + etcd. Workers are separate agent nodes.
# A VIP/LB (HAProxy, kube-vip, or Oracle LB) fronts the API server on port 6443.
#
# Usage:
#   On server-1: NODE_ROLE=init   bash k3s-ha-3-node-embedded-etcd-setup.sh
#   On server-2: NODE_ROLE=join   bash k3s-ha-3-node-embedded-etcd-setup.sh
#   On server-3: NODE_ROLE=join   bash k3s-ha-3-node-embedded-etcd-setup.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
K3S_VERSION="v1.28.5+k3s1"
NODE_ROLE="${NODE_ROLE:-init}"          # "init" for first node, "join" for others
SERVER1_IP="10.10.0.5"                 # Bootstrap server IP
SERVER2_IP="10.10.0.6"
SERVER3_IP="10.10.0.7"
VIP="10.10.0.10"                       # Virtual IP (HAProxy/kube-vip) fronting all 3 servers
K3S_TOKEN="${K3S_TOKEN:-changeme-secret-token}"  # Shared secret — set via env var
CLUSTER_DNS="cluster.local"

# ── Common setup (run on all nodes) ───────────────────────────────────────────
common_setup() {
  echo "[INFO] Running common pre-flight on $(hostname)..."
  swapoff -a
  sed -i '/swap/d' /etc/fstab

  modprobe overlay
  modprobe br_netfilter

  cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system

  # Open required ports in firewall (if firewalld is active)
  if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port=6443/tcp   # K8s API server
    firewall-cmd --permanent --add-port=2379/tcp   # etcd client
    firewall-cmd --permanent --add-port=2380/tcp   # etcd peer
    firewall-cmd --permanent --add-port=8472/udp   # Flannel VXLAN
    firewall-cmd --permanent --add-port=10250/tcp  # kubelet
    firewall-cmd --reload
  fi
}

# ── Bootstrap first server node (embedded etcd cluster-init) ─────────────────
init_server() {
  local node_ip="${SERVER1_IP}"
  echo "[INFO] Initializing HA cluster on ${node_ip} with embedded etcd..."

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="server \
      --cluster-init \
      --node-ip=${node_ip} \
      --tls-san=${node_ip} \
      --tls-san=${VIP} \
      --cluster-dns=${CLUSTER_DNS} \
      --write-kubeconfig-mode=644 \
      --disable=servicelb \
      --etcd-expose-metrics=true" \
    sh -

  echo "[INFO] Waiting for first server to become ready..."
  sleep 15
  kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml wait node \
    --all --for=condition=Ready --timeout=120s

  echo ""
  echo "[SUCCESS] Bootstrap node ready. Cluster token:"
  cat /var/lib/rancher/k3s/server/node-token
  echo ""
  echo "Run on server-2 and server-3:"
  echo "  NODE_ROLE=join K3S_TOKEN=<token> bash k3s-ha-3-node-embedded-etcd-setup.sh"
}

# ── Join additional server nodes ──────────────────────────────────────────────
join_server() {
  local node_ip
  # Detect which server this is by matching hostname/IP
  node_ip=$(hostname -I | awk '{print $1}')
  echo "[INFO] Joining HA cluster as server node ${node_ip}..."

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="server \
      --server=https://${SERVER1_IP}:6443 \
      --node-ip=${node_ip} \
      --tls-san=${node_ip} \
      --tls-san=${VIP} \
      --write-kubeconfig-mode=644 \
      --disable=servicelb" \
    sh -

  echo "[SUCCESS] Node ${node_ip} joined the HA cluster."
}

# ── Main ───────────────────────────────────────────────────────────────────────
common_setup

case "${NODE_ROLE}" in
  init) init_server ;;
  join) join_server ;;
  *)
    echo "[ERROR] NODE_ROLE must be 'init' or 'join'"
    exit 1
    ;;
esac

echo ""
echo "Verify cluster (from server-1):"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -n kube-system"
