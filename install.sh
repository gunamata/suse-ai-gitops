#!/bin/bash

# ================================================================
# User Instructions:
# ================================================================
# This script sets up a Rancher Kubernetes Environment (RKE2) with the necessary components such as Helm, Cert Manager, NGINX Ingress, and Rancher itself.
#
# Usage:
#   ./setup-rke2-cluster.sh [options]
#
# Options:
#   --force                Force installation even if cluster is already set up.
#   --dry-run              Run the script without making any changes (useful for testing).
#   --hostname=<hostname>   Set the hostname for Rancher (default: suse-ai-cluster-manager.xyz).
#   --bootstrap-password=<password>   Set the bootstrap password for Rancher (default: CHANGEME-<random>).
#   --email=<email>         Set the email address for Let's Encrypt (default: you@example.com).
#   --cert-type=<type>      Set the certificate type for Rancher (default: self-signed, options: self-signed, letsencrypt).
#   --ingress-mode=<mode>   Set the ingress mode for NGINX (default: hostport, options: hostport, nodeport).
#   --capi-provider=<provider> Set the CAPI provider to provision workload clusters (default: k3k options: aws, vcluster, k3k)
#   
# Example:
#   ./setup-rke2-cluster.sh --hostname=myrancher.example.com --bootstrap-password=SuperSecret123 --cert-type=letsencrypt
#
# ================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.0"
MARKER_PATH="/usr/local/share/setup-rke2-cluster.meta"
AUDIT_LOG="/var/log/setup-rke2-cluster.log"
INSTALLED_HELM="false"
INSTALLED_CLUSTERCTL="false"
INSTALLED_RKE2="false"
rancher_installed="false"
FORCE_INSTALL="false"
DRY_RUN="false"
CERT_TYPE="self-signed" # default value
INGRESS_MODE="hostport" # default value
CAPI_PROVIDER="k3k" # default value

RANCHER_HOSTNAME="suse-ai-cluster-manager.xyz"
RANCHER_PASSWORD="CHANGEME-$(openssl rand -hex 6)"
LETSENCRYPT_EMAIL="you@example.com"

log() {
  echo -e "[INFO] $1"
  echo "[INFO] $1" | $SUDO tee -a "$AUDIT_LOG" > /dev/null
}

error_exit() {
  echo -e "[ERROR] $1" >&2
  echo "[ERROR] $1" | $SUDO tee -a "$AUDIT_LOG" > /dev/null
  exit 1
}

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo &> /dev/null; then
    echo "[ERROR] This script requires root or sudo." >&2
    exit 1
  fi
  SUDO="sudo"
fi

for arg in "$@"; do
  case $arg in
    --force) FORCE_INSTALL="true" ;;
    --dry-run) DRY_RUN="true" ;;
    --hostname=*) RANCHER_HOSTNAME="${arg#*=}" ;;
    --bootstrap-password=*) RANCHER_PASSWORD="${arg#*=}" ;;
    --email=*) LETSENCRYPT_EMAIL="${arg#*=}" ;;
    --cert-type=*) CERT_TYPE="${arg#*=}" ;;
    --ingress-mode=*) INGRESS_MODE="${arg#*=}" ;;
    --capi-provider=*) CAPI_PROVIDER="${arg#*=}" ;;
    *) error_exit "Unknown argument: $arg" ;;
  esac
done

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
  else
    error_exit "Unsupported distro. /etc/os-release not found."
  fi

  case "$DISTRO" in
    ubuntu|debian)
      PKG_INSTALL="$SUDO apt-get install -y"
      PKG_UPDATE="$SUDO apt-get update"
      ;;
    centos|rhel|rocky|almalinux)
      PKG_INSTALL="$SUDO yum install -y"
      PKG_UPDATE="$SUDO yum update -y"
      # RKE2 doesn't like nm-cloud-setup.service
      # For more info, https://docs.rke2.io/known_issues?_highlight=nm&_highlight=cloud&_highlight=setup.service#networkmanager
      $SUDO systemctl disable nm-cloud-setup.service
      $SUDO systemctl stop nm-cloud-setup.service
      $SUDO systemctl mask nm-cloud-setup.service
      ;;
    fedora)
      PKG_INSTALL="$SUDO dnf install -y"
      PKG_UPDATE="$SUDO dnf update -y"
      ;;
    sles|suse|opensuse-leap)
      PKG_INSTALL="$SUDO zypper install -y"
      PKG_UPDATE="$SUDO zypper refresh"
      ;;
    *) error_exit "Unsupported Linux distro: $DISTRO" ;;
  esac
}

detect_arch() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) error_exit "Unsupported architecture: $ARCH" ;;
  esac
}

check_marker_exists() {
  if [[ -f "$MARKER_PATH" && "$FORCE_INSTALL" != "true" && "$DRY_RUN" != "true" ]]; then
    log "Marker file found. Cluster appears to be set up. Use --force to reinstall."
    exit 0
  fi
}

cluster_ready() {
  command -v kubectl &> /dev/null &&   kubectl version &> /dev/null &&   kubectl get nodes &> /dev/null
}

install_rke2() {
  log "Installing RKE2..."
  $DRY_RUN && return

  curl -sfL https://get.rke2.io | $SUDO sh -
  
  log "Disabling RKE2 bundled ingress-nginx..."
  $SUDO mkdir -p /etc/rancher/rke2
  $SUDO tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
disable:
  - rke2-ingress-nginx
EOF

  $SUDO systemctl enable rke2-server
  $SUDO systemctl start rke2-server

  mkdir -p ~/.kube
  $SUDO cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
  $SUDO chown $(id -u):$(id -g) ~/.kube/config
  export KUBECONFIG=~/.kube/config

  INSTALLED_RKE2="true"
}

ensure_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    if [ -f /var/lib/rancher/rke2/bin/kubectl ]; then
      log "Linking kubectl..."
      $DRY_RUN || $SUDO ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
    else
      error_exit "kubectl not found."
    fi
  fi

  log "Waiting for RKE2 to become ready..."
  MAX_WAIT=300
  WAIT_INTERVAL=3
  ELAPSED=0

  while true; do
    if [ ! -f "$KUBECONFIG" ]; then
      log "Kubeconfig not found at $KUBECONFIG yet..."
    elif ! kubectl get nodes &> /dev/null; then
      log "kubectl not ready yet, retrying..."
    else
      log "Kubeconfig is present and kubectl is working."
      break
    fi

    if (( ELAPSED >= MAX_WAIT )); then
      error_exit "Timed out waiting for RKE2/kubectl to become ready. Check RKE2 logs and KUBECONFIG permissions."
    fi

    sleep "$WAIT_INTERVAL"
    ELAPSED=$(( ELAPSED + WAIT_INTERVAL ))
  done
}

install_curl() {
  if ! command -v curl &> /dev/null; then
    log "Installing curl..."
    $DRY_RUN || {
      $PKG_UPDATE
      $PKG_INSTALL curl
    }
  fi
}

install_clusterctl() {
  if command -v clusterctl &> /dev/null; then
    log "clusterctl already installed."
    return
  fi

  TMP_DIR=$(mktemp -d)
  detect_arch
  log "Installing the latest version of clusterctl for $ARCH"
  $DRY_RUN && return

  curl -sSL "https://github.com/kubernetes-sigs/cluster-api/releases/latest/download/clusterctl-linux-$ARCH" -o "$TMP_DIR/clusterctl"

  $SUDO install -o root -g root -m 0755 "$TMP_DIR/clusterctl" /usr/local/bin/clusterctl
  rm -rf "$TMP_DIR"

  INSTALLED_CLUSTERCTL="true"
}


install_helm() {
  if command -v helm &> /dev/null; then
    log "Helm already installed."
    return
  fi
  HELM_VERSION="v3.14.0"
  TMP_DIR=$(mktemp -d)
  detect_arch
  log "Installing Helm $HELM_VERSION for $ARCH"
  $DRY_RUN && return

  curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o "$TMP_DIR/helm.tar.gz"
  tar -xzf "$TMP_DIR/helm.tar.gz" -C "$TMP_DIR"
  $SUDO mv "$TMP_DIR/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "$TMP_DIR"

  INSTALLED_HELM="true"
}

install_cert_manager() {
  if kubectl get ns cert-manager &> /dev/null; then
    log "cert-manager already installed."
    return
  fi
  log "Installing cert-manager..."
  $DRY_RUN && return
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm install cert-manager jetstack/cert-manager --namespace cert-manager --set installCRDs=true --version v1.14.4 --create-namespace
  kubectl rollout status deploy/cert-manager -n cert-manager --timeout=3m
  kubectl rollout status deploy/cert-manager-webhook -n cert-manager --timeout=3m
}

install_nginx_ingress() {
  if kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[*].status.phase}' | grep -q Running; then
    log "NGINX Ingress already installed."
    return
  fi
  log "Installing NGINX Ingress Controller..."
  $DRY_RUN && return
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  if [[ "$INGRESS_MODE" == "hostport" ]]; then
    helm install nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --set controller.kind=DaemonSet \
      --set controller.hostNetwork=true \
      --set controller.daemonset.useHostPort=true \
      --set controller.service.type=ClusterIP \
      --set controller.admissionWebhooks.enabled=false \
      --set controller.ingressClassResource.name=nginx \
      --set controller.ingressClass=nginx \
      --create-namespace
    log "Waiting for NGINX ingress controller pods to be ready..."
    kubectl rollout status daemonset nginx-ingress-nginx-controller -n ingress-nginx --timeout=3m
  elif [[ "$INGRESS_MODE" == "nodeport" ]]; then
    helm install nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --set controller.service.type=NodePort \
      --set controller.admissionWebhooks.enabled=false \
      --set controller.ingressClassResource.name=nginx \
      --set controller.ingressClass=nginx \
      --create-namespace
    log "Waiting for NGINX ingress controller pods to be ready..."
    kubectl rollout status deployment nginx-ingress-controller -n ingress-nginx --timeout=3m
  else
    error_exit "Invalid ingress mode: $INGRESS_MODE. Use hostport or nodeport."
  fi
  
}

install_rancher() {
  # Check if Rancher is installed and running
  if kubectl get deployment rancher -n cattle-system &>/dev/null; then
    available_replicas=$(kubectl get deployment rancher -n cattle-system -o jsonpath='{.status.availableReplicas}')
    if [[ "$available_replicas" -ge 3 ]]; then
      log "Rancher is already installed and running."
      return
    else
      log "Rancher deployment exists but is not ready."
    fi
  elif kubectl get ns cattle-system &>/dev/null; then
    log "cattle-system namespace exists but Rancher is not fully deployed."
  fi

  
  local tls_source="secret"
  if [[ "$CERT_TYPE" == "letsencrypt" ]]; then
    tls_source="letsEncrypt"
  fi

  log "Installing Rancher (cert: $tls_source)..."
  $DRY_RUN && return
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  helm repo update
  helm install rancher rancher-latest/rancher \
    --namespace cattle-system \
    --set hostname="$RANCHER_HOSTNAME" \
    --set replicas=3 \
    --set bootstrapPassword="$RANCHER_PASSWORD" \
    --set ingress.tls.source="$tls_source" \
    --set ingress.ingressClassName=nginx \
    $( [[ "$tls_source" == "letsEncrypt" ]] && echo "--set letsEncrypt.email=$LETSENCRYPT_EMAIL" ) \
    --create-namespace
  kubectl rollout status deploy/rancher -n cattle-system --timeout=10m
  rancher_installed="true"
}

install_k3k() {
  if kubectl get ns k3k-system &> /dev/null; then
    log "k3k already installed."
    return
  fi

  helm repo add k3k https://rancher.github.io/k3k
  helm repo update
  helm install --namespace k3k-system --create-namespace k3k k3k/k3k --devel
}

install_capi() {
  if kubectl get ns rancher-turtles-system &> /dev/null; then
    log "CAPI already installed."
    return
  fi
  log "Installing CAPI..."
  $DRY_RUN && return
  helm repo add turtles https://rancher.github.io/turtles
  helm repo update
  helm install rancher-turtles turtles/rancher-turtles --version v0.16.0 \
    -n rancher-turtles-system \
    --dependency-update \
    --create-namespace --wait \
    --timeout 3m
  
  kubectl rollout status deploy/rancher-turtles-cluster-api-operator -n rancher-turtles-system --timeout=3m
  kubectl rollout status deploy/rancher-turtles-controller-manager -n rancher-turtles-system --timeout=3m
    
  if [ "$CAPI_PROVIDER" == "vcluster" ]; then
    clusterctl init --infrastructure vcluster
  elif [ "$CAPI_PROVIDER" == "k3k" ]; then
    # There's no CAPI provider for k3k yet. Just using k3k chart for now.
    install_k3k
  else
    log "CAPI Provider not supported yet!"
  fi
}

write_marker_file() {
  [ "$DRY_RUN" = "true" ] && return
  log "Writing install marker to $MARKER_PATH"
  $SUDO tee "$MARKER_PATH" > /dev/null <<EOF
installed_by=setup-rke2-cluster.sh
version=$SCRIPT_VERSION
arch=$(uname -m)
date=$(date -Iseconds)
rke2=$INSTALLED_RKE2
helm=$INSTALLED_HELM
clusterctl=$INSTALLED_CLUSTERCTL
rancher=$rancher_installed
EOF
}

log "<dfe2> Starting setup script (v$SCRIPT_VERSION) at $(date)"
$SUDO touch "$AUDIT_LOG" && $SUDO chmod 644 "$AUDIT_LOG"

detect_os
install_curl
check_marker_exists

if cluster_ready && [ "$FORCE_INSTALL" = "false" ] && [ "$DRY_RUN" = "false" ]; then
  log "Cluster already running. Skipping RKE2 install."
else
  install_rke2
  ensure_kubectl
fi

install_clusterctl
install_helm
install_cert_manager
install_nginx_ingress
install_rancher
install_capi
write_marker_file
log "✅ Setup complete (dry-run=$DRY_RUN). Audit log: $AUDIT_LOG"
