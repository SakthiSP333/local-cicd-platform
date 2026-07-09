#!/usr/bin/env bash

set -euo pipefail

# Determine paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_DIR="${WORKSPACE_DIR}/bin"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

# Create local bin directory
mkdir -p "${BIN_DIR}"
export PATH="${BIN_DIR}:${PATH}"

log "Local bin directory: ${BIN_DIR}"

# Helper to check if binary exists locally or globally
check_tool() {
    local tool_name=$1
    if command -v "${tool_name}" &>/dev/null; then
        log "Tool '${tool_name}' is already installed: $(command -v "${tool_name}")"
        return 0
    fi
    return 1
}

# Determine OS and Arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) log_error "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

log "Detected OS: ${OS}, Arch: ${ARCH}"

# Install kubectl
if ! check_tool "kubectl"; then
    log "Downloading kubectl..."
    KUBECTL_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
    curl -Lo "${BIN_DIR}/kubectl" "https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
    chmod +x "${BIN_DIR}/kubectl"
    log "kubectl installed successfully."
fi

# Install helm
if ! check_tool "helm"; then
    log "Downloading Helm..."
    HELM_VERSION="v3.12.3" # Locked stable version
    curl -Lo "${BIN_DIR}/helm.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
    tar -xzf "${BIN_DIR}/helm.tar.gz" -C "${BIN_DIR}" --strip-components=1 "${OS}-${ARCH}/helm"
    rm -f "${BIN_DIR}/helm.tar.gz"
    chmod +x "${BIN_DIR}/helm"
    log "Helm installed successfully."
fi

# Install yq
if ! check_tool "yq"; then
    log "Downloading yq..."
    YQ_VERSION="v4.35.2"
    curl -Lo "${BIN_DIR}/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
    chmod +x "${BIN_DIR}/yq"
    log "yq installed successfully."
fi

# Install trivy
if ! check_tool "trivy"; then
    log "Downloading Trivy..."
    
    # Use a recent version (0.72.0 as of mid-2026)
    TRIVY_VERSION="0.72.0"
    
    # Better arch mapping
    case "${ARCH}" in
        amd64|x86_64)
            TRIVY_ARCH="64bit"
            ;;
        arm64|aarch64)
            TRIVY_ARCH="ARM64"
            ;;
        *)
            log "Unsupported architecture: ${ARCH}"
            exit 1
            ;;
    esac
    
    TRIVY_OS="Linux"
    if [ "${OS}" = "darwin" ]; then 
        TRIVY_OS="macOS"
    fi
    
    DOWNLOAD_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${TRIVY_OS}-${TRIVY_ARCH}.tar.gz"
    
    log "Downloading from: ${DOWNLOAD_URL}"
    
    if ! curl -f -Lo "${BIN_DIR}/trivy.tar.gz" "${DOWNLOAD_URL}"; then
        log "Download failed. Check version/arch or network."
        exit 1
    fi
    
    tar -xzf "${BIN_DIR}/trivy.tar.gz" -C "${BIN_DIR}" trivy
    rm -f "${BIN_DIR}/trivy.tar.gz"
    chmod +x "${BIN_DIR}/trivy"
    log "Trivy installed successfully."
fi

# Install gosec
if ! check_tool "gosec"; then
    log "Downloading gosec..."
    GOSEC_VERSION="2.18.2"
    curl -Lo "${BIN_DIR}/gosec.tar.gz" "https://github.com/securego/gosec/releases/download/v${GOSEC_VERSION}/gosec_${GOSEC_VERSION}_${OS}_${ARCH}.tar.gz"
    tar -xzf "${BIN_DIR}/gosec.tar.gz" -C "${BIN_DIR}" gosec
    rm -f "${BIN_DIR}/gosec.tar.gz"
    chmod +x "${BIN_DIR}/gosec"
    log "gosec installed successfully."
fi

# Install gitleaks
if ! check_tool "gitleaks"; then
    log "Downloading gitleaks..."
    GITLEAKS_VERSION="8.18.0"
    curl -Lo "${BIN_DIR}/gitleaks.tar.gz" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${OS}_x64.tar.gz"
    # Check if aarch64 was selected
    if [ "${ARCH}" = "arm64" ]; then
        curl -Lo "${BIN_DIR}/gitleaks.tar.gz" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${OS}_arm64.tar.gz"
    fi
    tar -xzf "${BIN_DIR}/gitleaks.tar.gz" -C "${BIN_DIR}" gitleaks || {
        # Fallback if tar extraction fails or name differs
        tar -xzf "${BIN_DIR}/gitleaks.tar.gz" -C "${BIN_DIR}"
    }
    rm -f "${BIN_DIR}/gitleaks.tar.gz"
    chmod +x "${BIN_DIR}/gitleaks"
    log "gitleaks installed successfully."
fi

# Install golangci-lint
if ! check_tool "golangci-lint"; then
    log "Downloading golangci-lint..."
    GOLANGCI_VERSION="1.55.2"
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b "${BIN_DIR}" "v${GOLANGCI_VERSION}"
    log "golangci-lint installed successfully."
fi

# Verify everything
log "Verifying installed tools..."
for tool in kubectl helm yq trivy gosec gitleaks golangci-lint; do
    if command -v "${tool}" &>/dev/null; then
        log "  - ${tool}: $(command -v ${tool}) ($( "${tool}" version 2>&1 | head -n 1 || "${tool}" --version 2>&1 | head -n 1 ))"
    else
        log_error "  - ${tool} installation FAILED or not in PATH."
    fi
done

log "All tooling installation completed!"
