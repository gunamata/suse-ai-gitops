#!/bin/bash

set -euo pipefail

MARKER_PATH="/usr/local/share/setup-rke2-cluster.meta"
AUDIT_LOG="/var/log/setup-rke2-cluster.log"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo &> /dev/null; then
    echo "[ERROR] This script requires root or sudo." >&2
    exit 1
  fi
  SUDO="sudo"
fi

log() {
  echo -e "[INFO] $1"
  echo "[INFO] $1" | $SUDO tee -a "$AUDIT_LOG" > /dev/null
}

error_exit() {
  echo -e "[ERROR] $1" >&2
  echo "[ERROR] $1" | $SUDO tee -a "$AUDIT_LOG" > /dev/null
  exit 1
}

read_marker_file() {
  if [[ ! -f $MARKER_PATH ]]; then
    error_exit "Install marker not found. Aborting to avoid unintended removal."
  fi
  log "Reading install marker from $MARKER_PATH"
  source "$MARKER_PATH"
}

uninstall_rke2() {
  if [[ "${rke2:-false}" == "true" ]]; then
    log "Uninstalling RKE2..."
    $SUDO systemctl stop rke2-server || true
    $SUDO systemctl disable rke2-server || true
    $SUDO rm -rf /etc/rancher /var/lib/rancher /var/lib/etcd
    $SUDO rm -f /usr/local/bin/rke2 /usr/local/bin/rke2-killall.sh /usr/local/bin/rke2-uninstall.sh
  else
    log "RKE2 was not installed by this script. Skipping."
  fi
}

remove_kubectl_symlink() {
  if [[ -L /usr/local/bin/kubectl ]] && [[ "$(readlink -f /usr/local/bin/kubectl)" == "/var/lib/rancher/rke2/bin/kubectl" ]]; then
    log "Removing kubectl symlink..."
    $SUDO rm -f /usr/local/bin/kubectl
  fi
}

remove_helm() {
  if [[ "${helm:-false}" == "true" ]]; then
    log "Removing Helm..."
    $SUDO rm -f /usr/local/bin/helm
  else
    log "Helm was not installed by this script. Skipping."
  fi
}

remove_clusterctl() {
  if [[ "${clusterctl:-false}" == "true" ]]; then
    log "Removing clusterctl..."
    $SUDO rm -f /usr/local/bin/clusterctl
  else
    log "clusterctl was not installed by this script. Skipping."
  fi
}

uninstall_capi() {
  if kubectl get ns rancher-turtles-system &>/dev/null; then
    log "Removing CAPI..."
    helm uninstall rancher-turtles -n rancher-turtles-system --timeout 60s || true
    kubectl delete ns rancher-turtles-system --timeout=60s --wait=true || log "[WARN] Timeout deleting rancher-turtles-system. May require manual cleanup."
  fi
}

uninstall_cert_manager() {
  if kubectl get ns cert-manager &>/dev/null; then
    log "Removing cert-manager..."
    helm uninstall cert-manager -n cert-manager --timeout 60s || true
    kubectl delete ns cert-manager --timeout=60s --wait=true || log "[WARN] Timeout deleting cert-manager. May require manual cleanup."
  fi
}

uninstall_nginx_ingress() {
  if kubectl get ns ingress-nginx &>/dev/null; then
    log "Removing NGINX..."
    helm uninstall nginx -n ingress-nginx --timeout 60s || true
    kubectl delete ns ingress-nginx --timeout=60s --wait=true || log "[WARN] Timeout deleting ingress-nginx. May require manual cleanup."
  fi
}

uninstall_rancher() {
  if kubectl get ns cattle-system &>/dev/null; then
    log "Removing Rancher..."
    helm uninstall rancher -n cattle-system --timeout 60s || true
    kubectl delete ns cattle-system --timeout=60s --wait=true || log "[WARN] Timeout deleting cattle-system. May require manual cleanup."
  fi
}

clean_bashrc_kubeconfig() {
  if grep -q "KUBECONFIG=/etc/rancher/rke2/rke2.yaml" ~/.bashrc; then
    log "Removing KUBECONFIG from ~/.bashrc"
    $SUDO sed -i '/KUBECONFIG=\/etc\/rancher\/rke2\/rke2.yaml/d' ~/.bashrc
  fi
}

clean_logs_and_marker() {
  log "Removing audit log and marker file..."
  $SUDO rm -f "$MARKER_PATH"
  $SUDO rm -f "$AUDIT_LOG"
}

log "🧼 Starting uninstall script"
read_marker_file
uninstall_capi
uninstall_rancher
uninstall_nginx_ingress
uninstall_cert_manager
remove_helm
remove_clusterctl
remove_kubectl_symlink
uninstall_rke2
clean_bashrc_kubeconfig
clean_logs_and_marker
log "✅ Uninstall complete"
