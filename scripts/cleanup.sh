#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARBOR_DIR="${WORKSPACE_DIR}/infrastructure/harbor"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] \033[1;33mCLEANUP:\033[0m $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] \033[1;31mERROR:\033[0m $1" >&2
}

log "Starting cleanup of local CI/CD resources..."

# 1. Stop Jenkins
if docker ps -a --format '{{.Names}}' | grep -Eq "^jenkins-local$"; then
    log "Stopping and removing Jenkins container..."
    docker stop jenkins-local || true
    docker rm jenkins-local || true
fi

# 2. Stop Harbor
if [ -d "${HARBOR_DIR}" ] && [ -f "${HARBOR_DIR}/docker-compose.yml" ]; then
    log "Stopping Harbor docker-compose services..."
    cd "${HARBOR_DIR}"
    docker compose down -v || true
fi

# 3. Stop and delete Minikube (this also tears down the monitoring stack and ArgoCD
# installed inside it, so there's nothing extra to `helm uninstall` first)
MINIKUBE_CMD="minikube"
if ! command -v minikube &>/dev/null; then
    if [ -f "${WORKSPACE_DIR}/bin/minikube" ]; then
        MINIKUBE_CMD="${WORKSPACE_DIR}/bin/minikube"
    fi
fi

if command -v "${MINIKUBE_CMD}" &>/dev/null; then
    log "Deleting Minikube cluster..."
    "${MINIKUBE_CMD}" delete || true
fi

# 4. Clean up directories and environment files
log "Removing local database folders, artifacts, and credential variables..."
rm -f "${WORKSPACE_DIR}/infrastructure/harbor-robot.env"
rm -f "${WORKSPACE_DIR}/infrastructure/argocd-creds.env"
rm -f "${WORKSPACE_DIR}/infrastructure/jenkins-creds.env"
rm -f "${WORKSPACE_DIR}/infrastructure/monitoring-creds.env"
rm -rf "${WORKSPACE_DIR}/infrastructure/jenkins/jenkins_home"
rm -rf "${HARBOR_DIR}/data"

# Optional: clean bin tools folder
# Uncomment if we want a fresh tools reinstall
# rm -rf "${WORKSPACE_DIR}/bin"

log "Cleanup completed successfully!"
