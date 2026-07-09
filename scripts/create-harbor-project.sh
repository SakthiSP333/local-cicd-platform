#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREDS_FILE="${WORKSPACE_DIR}/infrastructure/harbor-robot.env"

# Logger
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

log_error() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

HARBOR_URL="http://localhost:8082"
HARBOR_API="${HARBOR_URL}/api/v2.0"
ADMIN_USER="admin"
ADMIN_PASS="Harbor12345"

log "Waiting for Harbor API to become responsive..."

until curl -s -f "${HARBOR_API}/ping" >/dev/null; do
    log "Harbor API is not ready yet. Retrying in 5 seconds..."
    sleep 5
done

log "Harbor API is healthy!"

#------------------------------------------------------------
# Check if project exists
#------------------------------------------------------------
project_exists() {
    local project_name=$1

    local status
    status=$(curl -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -s \
        -o /dev/null \
        -w "%{http_code}" \
        "${HARBOR_API}/projects/${project_name}")

    [[ "${status}" == "200" ]]
}

PROJECT="library"

if project_exists "${PROJECT}"; then
    log "Project '${PROJECT}' already exists."
else
    log "Creating project '${PROJECT}'..."

    curl -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -s \
        -f \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{
              "project_name":"'"${PROJECT}"'",
              "metadata":{"public":"true"}
            }' \
        "${HARBOR_API}/projects"

    log "Project '${PROJECT}' created successfully."
fi

#------------------------------------------------------------
# Get robot ID (reliable lookup)
#------------------------------------------------------------
get_robot_id() {
    curl -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -s \
        "${HARBOR_API}/robots" |
    jq -r '.[] | select(.name=="robot$jenkins-robot") | .id' |
    head -n1
}

ROBOT_ID="$(get_robot_id)"

log "Detected ROBOT_ID='${ROBOT_ID}'"

#------------------------------------------------------------
# Robot already exists and creds file exists
#------------------------------------------------------------
if [[ -n "${ROBOT_ID}" && -f "${CREDS_FILE}" ]]; then
    log "Robot account 'jenkins-robot' already exists and credentials file is present."
    exit 0
fi

#------------------------------------------------------------
# Robot exists but creds file missing
#------------------------------------------------------------
if [[ -n "${ROBOT_ID}" ]]; then
    log "Robot exists but credentials file is missing."
    log "Deleting robot so it can be recreated..."

    curl -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -s \
        -f \
        -X DELETE \
        "${HARBOR_API}/robots/${ROBOT_ID}"

    ROBOT_ID=""
fi

#------------------------------------------------------------
# Create robot
#------------------------------------------------------------
log "Creating robot account 'jenkins-robot'..."

ROBOT_JSON=$(cat <<EOF
{
  "name": "jenkins-robot",
  "duration": -1,
  "description": "Robot for Jenkins CI/CD pipeline",
  "level": "system",
  "disable": false,
  "permissions": [
    {
      "kind": "project",
      "namespace": "${PROJECT}",
      "access": [
        {
          "resource": "repository",
          "action": "push"
        },
        {
          "resource": "repository",
          "action": "pull"
        },
        {
          "resource": "artifact",
          "action": "create"
        },
        {
          "resource": "artifact",
          "action": "delete"
        }
      ]
    }
  ]
}
EOF
)

RESPONSE=$(curl \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -s \
    -f \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${ROBOT_JSON}" \
    "${HARBOR_API}/robots")

#------------------------------------------------------------
# Check Harbor returned an error
#------------------------------------------------------------
if echo "${RESPONSE}" | jq -e '.errors' >/dev/null 2>&1; then
    log_error "Failed to create robot."
    echo "${RESPONSE}" | jq .
    exit 1
fi

ROBOT_NAME=$(echo "${RESPONSE}" | jq -r '.name')
ROBOT_SECRET=$(echo "${RESPONSE}" | jq -r '.secret')

if [[ -z "${ROBOT_NAME}" || "${ROBOT_NAME}" == "null" ]]; then
    log_error "Robot name not found in Harbor response."
    echo "${RESPONSE}" | jq .
    exit 1
fi

if [[ -z "${ROBOT_SECRET}" || "${ROBOT_SECRET}" == "null" ]]; then
    log_error "Robot secret not found in Harbor response."
    echo "${RESPONSE}" | jq .
    exit 1
fi

mkdir -p "$(dirname "${CREDS_FILE}")"

# Single-quote values in the written file (not here) - Harbor's system-robot names contain
# a literal '$' (e.g. "robot$jenkins-robot"), which would be mangled by anything that
# later `source`s this file unquoted.
cat > "${CREDS_FILE}" <<EOF
HARBOR_REGISTRY=localhost:8082
HARBOR_PROJECT=${PROJECT}
HARBOR_ROBOT_USER='${ROBOT_NAME}'
HARBOR_ROBOT_SECRET='${ROBOT_SECRET}'
EOF

chmod 600 "${CREDS_FILE}"

log "Robot account created successfully."
log "Credentials saved to ${CREDS_FILE}"