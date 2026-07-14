#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARBOR_DIR="${WORKSPACE_DIR}/infrastructure/harbor"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

log "Setting up Harbor..."

# Create harbor installation folder
mkdir -p "${HARBOR_DIR}"

HARBOR_VERSION="v2.8.2"
TARBALL_NAME="harbor-online-installer-${HARBOR_VERSION}.tgz"
DOWNLOAD_URL="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${TARBALL_NAME}"

if [ ! -f "${HARBOR_DIR}/install.sh" ]; then
    log "Downloading Harbor Online Installer ${HARBOR_VERSION}..."
    curl -Lo "${HARBOR_DIR}/${TARBALL_NAME}" "${DOWNLOAD_URL}"
    log "Extracting Harbor installer..."
    tar -xzf "${HARBOR_DIR}/${TARBALL_NAME}" -C "${WORKSPACE_DIR}/infrastructure"
    rm -f "${HARBOR_DIR}/${TARBALL_NAME}"
fi

# Configure harbor
log "Configuring Harbor..."
cp "${HARBOR_DIR}/harbor.yml.tmpl" "${HARBOR_DIR}/harbor.yml"

# Use yq or sed to modify harbor.yml
# We need to disable HTTPS and set HTTP port to 8082 to avoid conflict with Jenkins (8080)
#
# hostname must NOT be "localhost": Harbor embeds it in the registry's WWW-Authenticate
# token-realm URL, and "localhost" resolves to whichever machine is asking - that's fine
# for Jenkins (it pushes over the host's Docker socket) but breaks image pulls from
# Minikube's own Docker daemon, since its "localhost" is the Minikube node, not the host.
# Use the address Minikube maps host.minikube.internal to instead - reachable from both
# the host and from inside Minikube.
MINIKUBE_HOST_IP="$(minikube ssh -- getent hosts host.minikube.internal 2>/dev/null | awk '{print $1}')"
if [ -z "${MINIKUBE_HOST_IP}" ]; then
    log_error "Could not resolve host.minikube.internal from inside Minikube; is Minikube running?"
    exit 1
fi
sed -i "s/^hostname: .*/hostname: ${MINIKUBE_HOST_IP}/" "${HARBOR_DIR}/harbor.yml"
sed -i 's/^  port: 80/  port: 8082/' "${HARBOR_DIR}/harbor.yml"

# Comment out HTTPS block
# We do this by finding the line containing "https:" and commenting it and subsequent lines
sed -i '/^https:/,/^  certificate:/ s/^/#/' "${HARBOR_DIR}/harbor.yml"

# Check if data_volume path is inside our workspace so we don't pollute the host root
sed -i "s|^data_volume: .*|data_volume: ${HARBOR_DIR}/data|" "${HARBOR_DIR}/harbor.yml"

# Run install script
log "Running Harbor installation script (pulling docker images)..."
cd "${HARBOR_DIR}"
./install.sh --with-trivy || {
    log_error "Harbor installation failed. Retrying without Trivy (you can run security scans locally via CLI)..."
    ./install.sh
}

log "Harbor is now running on http://localhost:8082 (admin / Harbor12345)"
