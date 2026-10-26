#!/usr/bin/env bash
# L3: K3s — 3-Node HA Cluster with Embedded etcd
# K3s supports HA via embedded etcd (Raft consensus) — no external etcd required.
# Minimum 3 server nodes for quorum (tolerates 1 failure).
# Architecture:
#   server-1 — bootstrap node (--cluster-init)
#   server-2 — joins server-1
#   server-3 — joins server-1
#
# All 3 nodes run control-plane + etcd. Workers are separate agent nodes.
# A VIP/LB (HAProxy, kube-vip, or a cloud LB) fronts the API server on port 6443 (optional).
#
# Required environment (no defaults on purpose — real IPs and tokens do not belong in a repository):
#   K3S_TOKEN    shared cluster secret, the same on all servers (e.g. `openssl rand -hex 24`)
#   SERVER1_IP   address of the bootstrap server (joining servers connect to it)
#   VIP          optional: virtual IP / DNS name of the load balancer, added to the API certificate
# Optional: K3S_VERSION, NODE_IP (this node's IP; autodetected on join), DRY_RUN=1 (print the install
#           command instead of running it — this is what CI uses, a 3-node cluster does not fit a runner)
#
# Usage:
#   On server-1: NODE_ROLE=init K3S_TOKEN=... SERVER1_IP=... sudo -E bash k3s-ha-3-node-embedded-etcd-setup.sh
#   On server-2: NODE_ROLE=join K3S_TOKEN=... SERVER1_IP=... sudo -E bash k3s-ha-3-node-embedded-etcd-setup.sh
#   On server-3: NODE_ROLE=join K3S_TOKEN=... SERVER1_IP=... sudo -E bash k3s-ha-3-node-embedded-etcd-setup.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"
NODE_ROLE="${NODE_ROLE:-init}"          # "init" for first node, "join" for others
K3S_TOKEN="${K3S_TOKEN:?set K3S_TOKEN (shared secret, same on every server)}"
SERVER1_IP="${SERVER1_IP:?set SERVER1_IP (address of the bootstrap server)}"
VIP="${VIP:-}"
DRY_RUN="${DRY_RUN:-0}"

# Flags every server needs. They must be identical across servers: K3s refuses to join a node whose
# cluster-wide settings (cluster CIDR, cluster DNS, disabled components) differ from the cluster's.
# (--cluster-dns would be the *IP* of CoreDNS; the DNS suffix is --cluster-domain, default cluster.local.)
common_flags() {
  local node_ip="$1"
  printf '%s\n' \
    "--node-ip=${node_ip}" \
    "--tls-san=${node_ip}" \
    "--write-kubeconfig-mode=644" \
    "--etcd-expose-metrics=true"
  if [[ -n "${VIP}" ]]; then
    printf '%s\n' "--tls-san=${VIP}"
  fi
}

# ── Common setup (run on all nodes) ───────────────────────────────────────────
common_setup() {
  echo "[INFO] Running common pre-flight on $(hostname)..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY-RUN] skipping kernel modules, sysctl and firewall changes"
    return
  fi

  modprobe overlay
  modprobe br_netfilter

  cat > /etc/sysctl.d/99-kubernetes.conf <<EOF2
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF2
  sysctl --system >/dev/null

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

# install_k3s <flags...>: run the official installer, or print what it would run.
install_k3s() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY-RUN] INSTALL_K3S_VERSION=${K3S_VERSION} INSTALL_K3S_EXEC=\"server $*\" (K3S_TOKEN omitted)"
    return
  fi
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="server $*" \
    sh -
}

detect_node_ip() {
  if [[ -n "${NODE_IP:-}" ]]; then
    echo "${NODE_IP}"
  else
    hostname -I | awk '{print $1}'
  fi
}

# ── Bootstrap first server node (embedded etcd cluster-init) ─────────────────
init_server() {
  local node_ip
  node_ip="${NODE_IP:-${SERVER1_IP}}"
  echo "[INFO] Initializing HA cluster on ${node_ip} with embedded etcd..."

  local flags=()
  mapfile -t flags < <(common_flags "${node_ip}")
  install_k3s --cluster-init "${flags[@]}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    return
  fi
  echo "[INFO] Waiting for first server to become ready..."
  until kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes >/dev/null 2>&1; do sleep 2; done
  kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml wait node \
    --all --for=condition=Ready --timeout=180s

  echo ""
  echo "[SUCCESS] Bootstrap node ready. Join the other servers with the same K3S_TOKEN:"
  echo "  NODE_ROLE=join K3S_TOKEN=<same token> SERVER1_IP=${SERVER1_IP} bash $0"
}

# ── Join additional server nodes ──────────────────────────────────────────────
join_server() {
  local node_ip
  node_ip="$(detect_node_ip)"
  echo "[INFO] Joining HA cluster as server node ${node_ip}..."

  local flags=()
  mapfile -t flags < <(common_flags "${node_ip}")
  install_k3s "--server=https://${SERVER1_IP}:6443" "${flags[@]}"

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
