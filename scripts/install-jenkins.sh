#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JENKINS_DIR="${WORKSPACE_DIR}/infrastructure/jenkins"
JENKINS_HOME_DIR="${JENKINS_DIR}/jenkins_home"
HARBOR_CREDS_FILE="${WORKSPACE_DIR}/infrastructure/harbor-robot.env"
JENKINS_CREDS_FILE="${WORKSPACE_DIR}/infrastructure/jenkins-creds.env"

# GitHub identity Jenkins pushes go-api-helm version bumps as. Override via env if you
# forked this under a different account.
GITHUB_USER="${GITHUB_USER:-SakthiSP333}"
PERSONAL_SSH_KEY="${PERSONAL_SSH_KEY:-$HOME/.ssh/id_ed25519_personal}"

JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-$(openssl rand -hex 12 2>/dev/null || date +%s%N)}"

# Logger
log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

log_error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

log "Setting up Jenkins..."

if [ ! -f "${JENKINS_DIR}/Dockerfile" ]; then
    log_error "Dockerfile not found at ${JENKINS_DIR}/Dockerfile."
    exit 1
fi

if [ ! -f "${PERSONAL_SSH_KEY}" ]; then
    log_error "Personal GitHub SSH key not found at ${PERSONAL_SSH_KEY}."
    log_error "Set PERSONAL_SSH_KEY to point at the key registered with github.com/${GITHUB_USER}."
    exit 1
fi

if [ ! -f "${HARBOR_CREDS_FILE}" ]; then
    log_error "Harbor robot credentials not found at ${HARBOR_CREDS_FILE}. Run create-harbor-project.sh first."
    exit 1
fi
# Parse directly instead of `source`-ing: Harbor's robot username contains a literal '$'
# (e.g. "robot$jenkins-robot"), which an unquoted source would try to expand as a variable.
HARBOR_ROBOT_USER="$(grep '^HARBOR_ROBOT_USER=' "${HARBOR_CREDS_FILE}" | cut -d'=' -f2- | tr -d "'")"
HARBOR_ROBOT_SECRET="$(grep '^HARBOR_ROBOT_SECRET=' "${HARBOR_CREDS_FILE}" | cut -d'=' -f2- | tr -d "'")"

log "Building custom Jenkins docker image..."
docker build -t jenkins-local:latest "${JENKINS_DIR}"

# --- Provision Jenkins headlessly via init.groovy.d, so there's no browser setup wizard ---
mkdir -p "${JENKINS_HOME_DIR}/init.groovy.d"

log "Writing Jenkins bootstrap Groovy scripts..."

cat <<'GROOVY' > "${JENKINS_HOME_DIR}/init.groovy.d/00-security.groovy"
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.get()
def env = System.getenv()
String adminUser = env.getOrDefault('JENKINS_ADMIN_USER', 'admin')
String adminPassword = env.getOrDefault('JENKINS_ADMIN_PASSWORD', 'admin123')

def realm = new HudsonPrivateSecurityRealm(false)
if (realm.getAllUsers().isEmpty()) {
    realm.createAccount(adminUser, adminPassword)
    instance.setSecurityRealm(realm)

    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    strategy.setAllowAnonymousRead(false)
    instance.setAuthorizationStrategy(strategy)
    instance.save()
}
GROOVY

# Credentials contain secret material (SSH key, Harbor robot secret) - assemble them with
# printf so values are written verbatim, never re-interpreted by the shell (Harbor's robot
# username contains a literal '$', e.g. "robot$jenkins-robot", which would break if this
# were expanded through an unquoted heredoc).
{
    cat <<'GROOVY_HEAD'
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*
import com.cloudbees.jenkins.plugins.sshcredentials.impl.*

def instance = Jenkins.get()
def domain = Domain.global()
def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()
def existingIds = store.getCredentials(domain).collect { it.id }

def githubSshKey = '''
GROOVY_HEAD
    printf '%s\n' "$(cat "${PERSONAL_SSH_KEY}")"
    cat <<'GROOVY_MID'
'''

if (!existingIds.contains('github-personal-ssh')) {
    def keySource = new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(githubSshKey)
    def sshCred = new BasicSSHUserPrivateKey(
        CredentialsScope.GLOBAL,
        'github-personal-ssh',
        'git',
        keySource,
        '',
        'SSH key for pushing go-api-helm version bumps to GitHub'
    )
    store.addCredentials(domain, sshCred)
}

def harborUser = '''
GROOVY_MID
    printf '%s\n' "${HARBOR_ROBOT_USER}"
    cat <<'GROOVY_TAIL1'
'''
def harborSecret = '''
GROOVY_TAIL1
    printf '%s\n' "${HARBOR_ROBOT_SECRET}"
    cat <<'GROOVY_TAIL2'
'''

if (!existingIds.contains('harbor-robot')) {
    def harborCred = new UsernamePasswordCredentialsImpl(
        CredentialsScope.GLOBAL,
        'harbor-robot',
        'Harbor robot account for pushing go-api images',
        harborUser.trim(),
        harborSecret.trim()
    )
    store.addCredentials(domain, harborCred)
}
GROOVY_TAIL2
} > "${JENKINS_HOME_DIR}/init.groovy.d/10-credentials.groovy"

cat <<GROOVY > "${JENKINS_HOME_DIR}/init.groovy.d/20-seed-job.groovy"
import jenkins.model.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import hudson.plugins.git.GitSCM
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.UserRemoteConfig
import hudson.triggers.SCMTrigger

def instance = Jenkins.get()
def jobName = 'go-api-pipeline'

if (instance.getItem(jobName) == null) {
    def remoteConfigs = [new UserRemoteConfig('git@github.com:${GITHUB_USER}/go-api.git', 'origin', '', 'github-personal-ssh')]
    def branches = [new BranchSpec('*/main')]
    def scm = new GitSCM(remoteConfigs, branches, false, [], null, null, [])

    def flowDef = new CpsScmFlowDefinition(scm, 'Jenkinsfile')
    flowDef.setLightweight(true)

    def job = instance.createProject(WorkflowJob.class, jobName)
    job.setDefinition(flowDef)
    def trigger = new SCMTrigger('H/5 * * * *')
    job.addTrigger(trigger)
    trigger.start(job, true)
    job.save()
}
instance.save()
GROOVY

# Run Jenkins container
if docker ps -a --format '{{.Names}}' | grep -Eq "^jenkins-local$"; then
    log "Jenkins container already exists. Restarting..."
    docker stop jenkins-local || true
    docker rm jenkins-local || true
fi

log "Running Jenkins container on port 8080..."
# We mount the docker socket so Jenkins can drive the host's Docker daemon directly
# ("docker outside of docker") for image builds/pushes - no shared workspace path needed,
# `docker build .` streams its context over the socket regardless of where the client runs.
# GIT_SSH_COMMAND disables strict host key checking for the local learning sandbox only.
docker run -d \
    --name jenkins-local \
    -p 8080:8080 \
    -p 50000:50000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${JENKINS_HOME_DIR}:/var/jenkins_home" \
    -e JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER}" \
    -e JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD}" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    -u root \
    --restart unless-stopped \
    jenkins-local:latest

log "Waiting for Jenkins to start..."
until curl -s -f http://localhost:8080/login >/dev/null; do
    log "Jenkins is not ready yet. Retrying in 5 seconds..."
    sleep 5
done

cat <<EOF > "${JENKINS_CREDS_FILE}"
JENKINS_URL=http://localhost:8080
JENKINS_USER=${JENKINS_ADMIN_USER}
JENKINS_PASSWORD=${JENKINS_ADMIN_PASSWORD}
EOF
chmod 600 "${JENKINS_CREDS_FILE}"

log "Jenkins is ready!"
log "Jenkins URL: http://localhost:8080"
log "Admin user: ${JENKINS_ADMIN_USER}"
log "Admin password: ${JENKINS_ADMIN_PASSWORD}"
log "Credentials saved to: ${JENKINS_CREDS_FILE}"
log "Seeded pipeline job 'go-api-pipeline' polling git@github.com:${GITHUB_USER}/go-api.git every ~5 minutes."
