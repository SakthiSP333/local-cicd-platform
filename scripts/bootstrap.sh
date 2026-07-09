#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] \033[1;32mBOOTSTRAP:\033[0m $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] \033[1;31mERROR:\033[0m $1" >&2
}

log "Starting complete local CI/CD bootstrap..."

# 1. Install host development and security tools
log "Step 1: Installing CLI and validation tools..."
"${SCRIPT_DIR}/install-tools.sh"

# Add local bin to PATH for subsequent steps
export PATH="${WORKSPACE_DIR}/bin:${PATH}"

# 2. Check if Docker is running
log "Step 2: Checking Docker daemon..."
if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running. Please start Docker and retry."
    exit 1
fi
log "Docker is running."

# 3. Verify go-api and go-api-helm are real GitHub clones (Jenkins and ArgoCD both talk
# to GitHub directly now - there's no local git daemon in this flow).
log "Step 3: Verifying go-api and go-api-helm are checked out from GitHub..."
for repo in go-api go-api-helm; do
    if [ ! -d "${WORKSPACE_DIR}/${repo}/.git" ]; then
        log_error "${WORKSPACE_DIR}/${repo} is not a git checkout yet."
        log_error "Clone it first, e.g.: git clone git@github.com:SakthiSP333/${repo}.git ${WORKSPACE_DIR}/${repo}"
        exit 1
    fi
    if ! git -C "${WORKSPACE_DIR}/${repo}" remote get-url origin &>/dev/null; then
        log_error "${WORKSPACE_DIR}/${repo} has no 'origin' remote configured."
        exit 1
    fi
done
log "Found go-api/ and go-api-helm/ with GitHub remotes configured."

# 4. Start Minikube with insecure registry config pointing to Harbor
log "Step 4: Checking Minikube status..."
MINIKUBE_CMD="minikube"
if ! command -v minikube &>/dev/null; then
    if [ -f "${WORKSPACE_DIR}/bin/minikube" ]; then
        MINIKUBE_CMD="${WORKSPACE_DIR}/bin/minikube"
    else
        log "Downloading Minikube locally..."
        OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
        ARCH="$(uname -m)"
        case "${ARCH}" in
            x86_64) ARCH="amd64" ;;
            aarch64|arm64) ARCH="arm64" ;;
        esac
        curl -Lo "${WORKSPACE_DIR}/bin/minikube" "https://storage.googleapis.com/minikube/releases/latest/minikube-${OS}-${ARCH}"
        chmod +x "${WORKSPACE_DIR}/bin/minikube"
        MINIKUBE_CMD="${WORKSPACE_DIR}/bin/minikube"
    fi
fi

if ! "${MINIKUBE_CMD}" status &>/dev/null; then
    log "Starting Minikube with insecure registry 'host.minikube.internal:8082'..."
    "${MINIKUBE_CMD}" start \
        --driver=docker \
        --insecure-registry="host.minikube.internal:8082" \
        --addons=ingress,dashboard
else
    log "Minikube is already running."
fi

# Ensure kubectl points to Minikube context
kubectl config use-context minikube

log "Configuring K8s namespace for local deployments..."
kubectl create namespace go-api-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace go-api-stage --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace go-api-prod --dry-run=client -o yaml | kubectl apply -f -

# 5. Install Harbor (Image Registry)
log "Step 5: Bootstrapping Harbor Container Registry..."
"${SCRIPT_DIR}/install-harbor.sh"

# 6. Configure Harbor Projects and Robot Account
log "Step 6: Automating Harbor project and robot creation..."
"${SCRIPT_DIR}/create-harbor-project.sh"

# 7. Install monitoring (Prometheus + Grafana) - must land before ArgoCD's first sync,
# since go-api-helm's ServiceMonitor CRD only exists once the Prometheus Operator is installed.
log "Step 7: Bootstrapping Prometheus + Grafana monitoring stack..."
"${SCRIPT_DIR}/install-monitoring.sh"

# 8. Install Jenkins (CI Server)
log "Step 8: Bootstrapping Jenkins CI Engine..."
"${SCRIPT_DIR}/install-jenkins.sh"

# 9. Install ArgoCD (GitOps Engine)
log "Step 9: Bootstrapping ArgoCD GitOps Engine inside Minikube..."
"${SCRIPT_DIR}/install-argocd.sh"

log "--------------------------------------------------------"
log " Local CI/CD Platform Bootstrap completed successfully!"
log " Check the console output above for administration credentials."
log " Next steps:"
log "   1. Port forward services using 'make port-forward'"
log "   2. Push a commit to git@github.com:SakthiSP333/go-api.git - Jenkins polls it every ~5 min"
log "   3. ArgoCD is already syncing go-api-helm from git@github.com:SakthiSP333/go-api-helm.git"
log "   4. View metrics: 'make grafana-ui' (Prometheus + Grafana)"
log "--------------------------------------------------------"
