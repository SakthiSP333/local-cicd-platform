.PHONY: default setup bootstrap clean stop start restart logs port-forward jenkins-ui harbor-ui argocd-ui grafana-ui prometheus-ui test lint security

WORKSPACE_DIR := $(shell pwd)
SCRIPTS_DIR := $(WORKSPACE_DIR)/scripts

default: help

help:
	@echo "Local CI/CD GitOps Platform Control Center"
	@echo "=========================================="
	@echo "Orchestration:"
	@echo "  setup         - Complete end-to-end installation (bootstraps everything)"
	@echo "  clean         - Stops and cleans up all Docker services & Minikube"
	@echo "  start         - Starts docker stacks and Minikube VM"
	@echo "  stop          - Halts docker stacks and Minikube VM"
	@echo "  restart       - Full clean and rebuild setup"
	@echo ""
	@echo "Quality Control (App repository):"
	@echo "  test          - Run application test suites"
	@echo "  lint          - Check formatting and run golangci-lint"
	@echo "  security      - Run static analyzers (gosec, govulncheck, gitleaks, trivy)"
	@echo ""
	@echo "Port-Forwarding & UIs:"
	@echo "  jenkins-ui    - Opens Jenkins CI console (http://localhost:8080)"
	@echo "  harbor-ui     - Opens Harbor Registry (http://localhost:8082)"
	@echo "  argocd-ui     - Port-forwards and opens ArgoCD (https://localhost:8085)"
	@echo "  grafana-ui    - Port-forwards and opens Grafana dashboards (http://localhost:3000)"
	@echo "  prometheus-ui - Port-forwards and opens Prometheus (http://localhost:9090)"
	@echo "  port-forward  - Forwards Go-API ports: Dev (8081), Stage (8083), Prod (8084)"
	@echo "  logs-dev      - Stream Go API logs from dev cluster"
	@echo "  logs-stage    - Stream Go API logs from staging cluster"
	@echo "  logs-prod     - Stream Go API logs from prod cluster"

setup: bootstrap

bootstrap:
	@bash $(SCRIPTS_DIR)/bootstrap.sh

clean:
	@bash $(SCRIPTS_DIR)/cleanup.sh

start:
	@echo "Starting Minikube..."
	@minikube start || true
	@echo "Starting Harbor..."
	@if [ -d "$(WORKSPACE_DIR)/infrastructure/harbor" ]; then \
		cd $(WORKSPACE_DIR)/infrastructure/harbor && docker compose start; \
	fi
	@echo "Starting Jenkins..."
	@docker start jenkins-local || true
	@echo "Infrastructure services started."

stop:
	@echo "Stopping Jenkins..."
	@docker stop jenkins-local || true
	@echo "Stopping Harbor..."
	@if [ -d "$(WORKSPACE_DIR)/infrastructure/harbor" ]; then \
		cd $(WORKSPACE_DIR)/infrastructure/harbor && docker compose stop; \
	fi
	@echo "Stopping Minikube..."
	@minikube stop || true
	@echo "Infrastructure services stopped."

restart: clean bootstrap

# Local developer shortcuts
test:
	$(MAKE) -C go-api test

lint:
	$(MAKE) -C go-api lint

security:
	$(MAKE) -C go-api security

jenkins-ui:
	@echo "Opening Jenkins: http://localhost:8080"
	@if [ -f "$(WORKSPACE_DIR)/infrastructure/jenkins-creds.env" ]; then \
		echo "Jenkins credentials:"; \
		cat $(WORKSPACE_DIR)/infrastructure/jenkins-creds.env; \
	fi

harbor-ui:
	@echo "Opening Harbor: http://localhost:8082 (admin / Harbor12345)"

argocd-ui:
	@echo "Port-forwarding ArgoCD server to port 8085..."
	@if [ -f "$(WORKSPACE_DIR)/infrastructure/argocd-creds.env" ]; then \
		echo "ArgoCD credentials:"; \
		cat $(WORKSPACE_DIR)/infrastructure/argocd-creds.env; \
	fi
	kubectl port-forward svc/argocd-server -n argocd 8085:443

grafana-ui:
	@echo "Port-forwarding Grafana to port 3000..."
	@if [ -f "$(WORKSPACE_DIR)/infrastructure/monitoring-creds.env" ]; then \
		echo "Grafana credentials:"; \
		cat $(WORKSPACE_DIR)/infrastructure/monitoring-creds.env; \
	fi
	kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80

prometheus-ui:
	@echo "Port-forwarding Prometheus to port 9090..."
	kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090

port-forward:
	@echo "Port forwarding deployments (runs in foreground, Ctrl+C to terminate)..."
	@echo "  -> Dev environment: http://localhost:8081"
	@echo "  -> Stage environment: http://localhost:8083"
	@echo "  -> Prod environment: http://localhost:8084"
	@kubectl port-forward svc/go-api -n go-api-dev 8081:80 & \
	 kubectl port-forward svc/go-api -n go-api-stage 8083:80 & \
	 kubectl port-forward svc/go-api -n go-api-prod 8084:80 & \
	 wait

logs-dev:
	kubectl logs -l app.kubernetes.io/name=go-api -n go-api-dev -f --max-log-requests=10

logs-stage:
	kubectl logs -l app.kubernetes.io/name=go-api -n go-api-stage -f --max-log-requests=10

logs-prod:
	kubectl logs -l app.kubernetes.io/name=go-api -n go-api-prod -f --max-log-requests=10
