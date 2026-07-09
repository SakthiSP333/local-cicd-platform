#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREDS_FILE="${WORKSPACE_DIR}/infrastructure/argocd-creds.env"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

log "Setting up ArgoCD inside Minikube..."

# Ensure minikube is running and kubectl is talking to it
if ! kubectl cluster-info &>/dev/null; then
    log_error "Kubernetes cluster is not reachable. Please make sure Minikube is started."
    exit 1
fi

# Create namespace
log "Creating namespace 'argocd'..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD via official manifests
log "Applying ArgoCD stable manifests..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for deployments
log "Waiting for ArgoCD server components to be ready..."
kubectl rollout status deployment/argocd-dex-server -n argocd --timeout=300s || true
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s || true
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# Retrieve admin password
log "Retrieving ArgoCD initial admin password..."
until kubectl -n argocd get secret argocd-initial-admin-secret &>/dev/null; do
    log "Waiting for initial admin secret to be created..."
    sleep 3
done

PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Write credentials locally
cat <<EOF > "${CREDS_FILE}"
ARGOCD_URL=https://localhost:8085
ARGOCD_USER=admin
ARGOCD_PASSWORD=${PASSWORD}
EOF
chmod 600 "${CREDS_FILE}"

# Register the go-api Application so ArgoCD starts watching go-api-helm on GitHub.
# (application-set.yaml also exists for a dev/stage/prod fan-out once you're ready -
# apply it instead if you want all three environments; don't apply both, they'd both
# try to own an Application named "go-api-dev".)
APP_MANIFEST="${WORKSPACE_DIR}/go-api-helm/argocd/application.yaml"
if [ -f "${APP_MANIFEST}" ]; then
    log "Registering the go-api Application with ArgoCD..."
    kubectl apply -f "${APP_MANIFEST}"
else
    log_error "Application manifest not found at ${APP_MANIFEST} - skipping ArgoCD Application registration."
fi

log "ArgoCD is installed!"
log "Initial Admin Password: ${PASSWORD}"
log "Credentials saved to: ${CREDS_FILE}"
log "To access ArgoCD UI, run 'kubectl port-forward svc/argocd-server -n argocd 8085:443' and open https://localhost:8085"
