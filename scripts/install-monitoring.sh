#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREDS_FILE="${WORKSPACE_DIR}/infrastructure/monitoring-creds.env"
NAMESPACE="monitoring"
RELEASE_NAME="kube-prometheus-stack"
GRAFANA_ADMIN_PASSWORD="admin123"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

log "Setting up Prometheus + Grafana monitoring stack inside Minikube..."

# Ensure minikube is running and kubectl is talking to it
if ! kubectl cluster-info &>/dev/null; then
    log_error "Kubernetes cluster is not reachable. Please make sure Minikube is started."
    exit 1
fi

# Add/refresh the prometheus-community Helm repo
log "Adding 'prometheus-community' Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null || true
log "Updating Helm repos..."
helm repo update

# Create namespace
log "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Install/upgrade kube-prometheus-stack with laptop-friendly values:
# - no persistent storage (ephemeral, fine for a learning environment)
# - small resource requests/limits so it fits comfortably in a Minikube VM
# - Grafana admin password fixed & retrievable (written to creds file below)
log "Installing/upgrading '${RELEASE_NAME}' via Helm (this can take a few minutes on first run)..."
helm upgrade --install "${RELEASE_NAME}" prometheus-community/kube-prometheus-stack \
    -n "${NAMESPACE}" --create-namespace \
    --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
    --set grafana.persistence.enabled=false \
    --set grafana.resources.requests.cpu=50m \
    --set grafana.resources.requests.memory=128Mi \
    --set grafana.resources.limits.cpu=200m \
    --set grafana.resources.limits.memory=256Mi \
    --set grafana.sidecar.dashboards.enabled=true \
    --set grafana.sidecar.dashboards.searchNamespace=ALL \
    --set prometheus.prometheusSpec.storageSpec="" \
    --set prometheus.prometheusSpec.retention=6h \
    --set prometheus.prometheusSpec.resources.requests.cpu=100m \
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus.prometheusSpec.resources.limits.cpu=500m \
    --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set alertmanager.enabled=false \
    --set kubeStateMetrics.resources.requests.cpu=25m \
    --set kubeStateMetrics.resources.requests.memory=64Mi \
    --set nodeExporter.resources.requests.cpu=25m \
    --set nodeExporter.resources.requests.memory=32Mi \
    --wait --timeout 10m

# Wait for the key deployments to roll out
log "Waiting for Grafana to be ready..."
kubectl rollout status deployment/"${RELEASE_NAME}"-grafana -n "${NAMESPACE}" --timeout=300s

log "Waiting for the Prometheus Operator to be ready..."
kubectl rollout status deployment/"${RELEASE_NAME}"-operator -n "${NAMESPACE}" --timeout=300s || true

log "Waiting for the Prometheus StatefulSet to be ready..."
kubectl rollout status statefulset/prometheus-"${RELEASE_NAME}"-prometheus -n "${NAMESPACE}" --timeout=300s || true

# Write credentials locally
cat <<EOF > "${CREDS_FILE}"
GRAFANA_URL=http://localhost:3000
GRAFANA_USER=admin
GRAFANA_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
PROMETHEUS_URL=http://localhost:9090
EOF
chmod 600 "${CREDS_FILE}"

log "Monitoring stack is installed!"
log "Grafana Admin Password: ${GRAFANA_ADMIN_PASSWORD}"
log "Credentials saved to: ${CREDS_FILE}"
log "To access Grafana, run 'kubectl port-forward svc/${RELEASE_NAME}-grafana -n ${NAMESPACE} 3000:80' and open http://localhost:3000"
log "To access Prometheus, run 'kubectl port-forward svc/${RELEASE_NAME}-prometheus -n ${NAMESPACE} 9090:9090' and open http://localhost:9090"
