FROM jenkins/jenkins:lts-jdk17
USER root

# Install Docker CLI, git and ssh client (base image ships with neither)
RUN apt-get update && apt-get install -y lsb-release ca-certificates curl gnupg git openssh-client && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli

# Install Go
RUN curl -Lo go.tar.gz https://go.dev/dl/go1.21.5.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm -f go.tar.gz
ENV PATH=$PATH:/usr/local/bin:/usr/local/go/bin

# Install yq
RUN curl -Lo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.35.2/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

# Install security and linting tools
RUN curl -sfL https://raw.githubusercontent.com/securego/gosec/master/install.sh | sh -s -- -b /usr/local/bin v2.18.2 && \
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v0.45.1 && \
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b /usr/local/bin v1.55.2

# Install govulncheck
RUN curl -Lo /usr/local/bin/govulncheck-bin https://github.com/golang/vuln/releases/download/latest/govulncheck || true
# Let's compile govulncheck or use go install as root
RUN /usr/local/go/bin/go install golang.org/x/vuln/cmd/govulncheck@latest && \
    mv /root/go/bin/govulncheck /usr/local/bin/govulncheck

# Gitleaks
RUN curl -Lo gitleaks.tar.gz https://github.com/gitleaks/gitleaks/releases/download/v8.18.0/gitleaks_8.18.0_linux_x64.tar.gz && \
    tar -xzf gitleaks.tar.gz -C /usr/local/bin gitleaks && \
    rm -f gitleaks.tar.gz

# Syft (SBOM)
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

# Plugins needed for: GitHub SCM polling, SSH credentials (push to go-api-helm),
# and running the declarative pipeline itself (bare jenkins/jenkins images ship with none).
RUN jenkins-plugin-cli --plugins \
    git \
    workflow-aggregator \
    ssh-credentials \
    plain-credentials \
    credentials-binding \
    ssh-agent

# Add jenkins user back
USER jenkins

# Skip the interactive setup wizard - this container is provisioned headlessly via
# init.groovy.d scripts (see scripts/install-jenkins.sh), not through the browser wizard.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
