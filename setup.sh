#!/bin/bash
set -e

echo -e "╔════════════════════════════════════════════════════════════════╗"
echo -e "║  Phase 1: Metrics Foundation - Reliability Lab Setup          ║"
echo -e "║  Using kind + Docker                                          ║"
echo -e "╚════════════════════════════════════════════════════════════════╝"
echo -e ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Command output goes here; shown automatically if a step fails
LOG_FILE="/tmp/reliability-lab-setup.log"
: > "$LOG_FILE"
trap 'echo -e "\n❌ Setup failed. Last lines of $LOG_FILE:"; tail -n 30 "$LOG_FILE"' ERR

# Check prerequisites
echo -e "${BLUE}[1/7]${NC} Checking prerequisites..."
for cmd in kind kubectl helm docker; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "❌ $cmd is not installed"
        exit 1
    fi
done
if ! docker info >> "$LOG_FILE" 2>&1; then
    echo "❌ Docker is installed but the daemon isn't running"
    exit 1
fi
echo -e "${GREEN}✓${NC} All prerequisites found"
echo -e ""

# Create kind cluster
echo -e "${BLUE}[2/7]${NC} Setting up kind cluster..."
CLUSTER_NAME="reliability-lab"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo -e "${GREEN}✓${NC} Cluster '$CLUSTER_NAME' already exists"
else
    echo -e "Creating cluster '$CLUSTER_NAME'..."
    kind create cluster --name $CLUSTER_NAME --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  # Expose control-plane metrics beyond localhost so Prometheus can scrape them
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
      - name: bind-address
        value: 0.0.0.0
    scheduler:
      extraArgs:
      - name: bind-address
        value: 0.0.0.0
    etcd:
      local:
        extraArgs:
        - name: listen-metrics-urls
          value: http://0.0.0.0:2381
  - |
    kind: KubeProxyConfiguration
    metricsBindAddress: 0.0.0.0:10249
EOF
    echo -e "${GREEN}✓${NC} Cluster created"
fi

kubectl config use-context "kind-$CLUSTER_NAME" >> "$LOG_FILE" 2>&1
kubectl cluster-info >> "$LOG_FILE" 2>&1
echo -e ""

# Create monitoring namespace
echo -e "${BLUE}[3/7]${NC} Creating monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Namespace ready"
echo -e ""

# Add Helm repos
echo -e "${BLUE}[4/7]${NC} Adding Helm repositories..."
helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts >> "$LOG_FILE" 2>&1
helm repo update >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Repos added and updated"
echo -e ""

# Create Prometheus values
echo -e "${BLUE}[5/7]${NC} Creating Prometheus configuration..."
cat > /tmp/prometheus-values.yaml <<'VALUES_EOF'
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi

    retention: 15d
    scrapeInterval: 15s
    evaluationInterval: 15s

    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

grafana:
  enabled: true
  adminPassword: "admin123"
  persistence:
    enabled: true
    size: 2Gi

alertmanager:
  enabled: true
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
VALUES_EOF

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f /tmp/prometheus-values.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Prometheus stack deployed"
echo -e ""

# Wait for rollout
echo -e "${BLUE}[6/7]${NC} Waiting for components to be ready (this takes ~2-3 minutes)..."
kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=5m >> "$LOG_FILE" 2>&1
for _ in $(seq 1 60); do
    kubectl get statefulset/prometheus-prometheus-kube-prometheus-prometheus -n monitoring >> "$LOG_FILE" 2>&1 && break
    sleep 5
done
kubectl rollout status statefulset/prometheus-prometheus-kube-prometheus-prometheus -n monitoring --timeout=5m >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} All components ready"
echo -e ""

# Create alert rules
echo -e "${BLUE}[7/7]${NC} Installing alert rules..."
cat > /tmp/prometheus-rules.yaml <<'RULES_EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-alerts
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
  - name: cluster.rules
    interval: 30s
    rules:
    - alert: HighCPUUsage
      expr: (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.8
      for: 2m
      annotations:
        summary: "High CPU usage detected: {{ $value | humanizePercentage }}"

    - alert: HighMemoryUsage
      expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.85
      for: 2m
      annotations:
        summary: "High memory usage detected: {{ $value | humanizePercentage }}"

    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[15m]) > 0.1
      for: 5m
      annotations:
        summary: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} is crash looping"
RULES_EOF

kubectl apply -f /tmp/prometheus-rules.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Alert rules installed"
echo -e ""

# Verification
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Phase 1 Complete!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e ""

echo -e "Running pods:"
kubectl get pods -n monitoring --no-headers | sed 's/^/  /'
echo -e ""

echo -e "${YELLOW}NEXT STEPS:${NC}"
echo -e ""
echo -e "1. Make sure kubectl points at the lab cluster:"
echo -e "   ${BLUE}kubectl config use-context kind-reliability-lab${NC}"
echo -e ""
echo -e "2. Access Prometheus (run in one terminal):"
echo -e "   ${BLUE}kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090${NC}"
echo -e "   Then visit: ${GREEN}http://localhost:9090${NC}"
echo -e ""
echo -e "3. Access Grafana (run in another terminal):"
echo -e "   ${BLUE}kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80${NC}"
echo -e "   Then visit: ${GREEN}http://localhost:3000${NC}"
echo -e "   Login: ${BLUE}admin / admin123${NC}"
echo -e ""
echo -e "${YELLOW}VERIFY:${NC}"
echo -e "  • Prometheus Targets: http://localhost:9090/targets"
echo -e "  • Prometheus Alerts:  http://localhost:9090/alerts"
echo -e "  • Create dashboard in Grafana with query:"
echo -e "    ${BLUE}(1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))) * 100${NC}"
echo -e ""
echo -e "${YELLOW}CLEANUP (when done):${NC}"
echo -e "   ${BLUE}kind delete cluster --name reliability-lab${NC}"
echo -e ""
