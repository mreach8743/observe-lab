#!/bin/bash
set -e

echo -e "╔════════════════════════════════════════════════════════════════╗"
echo -e "║  Phase 2: Logging - Loki + Promtail                          ║"
echo -e "║  Requires Phase 1 (setup.sh) to have created the cluster     ║"
echo -e "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CLUSTER_NAME="reliability-lab"
LOG_FILE="/tmp/reliability-lab-phase2.log"
: > "$LOG_FILE"
trap 'echo -e "\n❌ Setup failed. Last lines of $LOG_FILE:"; tail -n 30 "$LOG_FILE"' ERR

# Check prerequisites
echo -e "${BLUE}[1/6]${NC} Checking prerequisites..."
for cmd in kind kubectl helm docker; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ $cmd is not installed"
        exit 1
    fi
done
if ! docker info >> "$LOG_FILE" 2>&1; then
    echo "❌ Docker is installed but the daemon isn't running"
    exit 1
fi
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "❌ Cluster '$CLUSTER_NAME' not found. Run ./setup.sh first (Phase 1)."
    exit 1
fi
kubectl config use-context "kind-$CLUSTER_NAME" >> "$LOG_FILE" 2>&1
if ! kubectl get deployment/prometheus-grafana -n monitoring >> "$LOG_FILE" 2>&1; then
    echo "❌ Phase 1 stack not found in namespace 'monitoring'. Run ./setup.sh first."
    exit 1
fi
echo -e "${GREEN}✓${NC} All prerequisites found"
echo ""

# Add Helm repo (idempotent, same repo used in Phase 1 for prometheus-community
# but Loki ships under the grafana/ repo)
echo -e "${BLUE}[2/6]${NC} Adding Grafana Helm repository..."
helm repo add --force-update grafana https://grafana.github.io/helm-charts >> "$LOG_FILE" 2>&1
helm repo update >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Repo added and updated"
echo ""

# Loki (single-binary mode, filesystem storage - fine for a lab)
echo -e "${BLUE}[3/6]${NC} Deploying Loki (single-binary, filesystem storage)..."
cat > /tmp/loki-values.yaml <<'VALUES_EOF'
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  limits_config:
    retention_period: 24h
  schemaConfig:
    configs:
    - from: "2024-01-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: loki_index_
        period: 24h
deploymentMode: SingleBinary
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 5Gi
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
gateway:
  enabled: false
test:
  enabled: false
lokiCanary:
  enabled: false
VALUES_EOF

helm upgrade --install loki grafana/loki \
  -n monitoring \
  -f /tmp/loki-values.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Loki deployed"
echo ""

# Promtail (daemonset that tails container logs on every node and ships to Loki)
echo -e "${BLUE}[4/6]${NC} Deploying Promtail..."
cat > /tmp/promtail-values.yaml <<'VALUES_EOF'
config:
  clients:
  - url: http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push
    tenant_id: ""
VALUES_EOF
# loki-stack's default Promtail config posts to the gateway; since we disabled
# the gateway above, point Promtail straight at the Loki service instead.
sed -i 's#http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push#http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push#' /tmp/promtail-values.yaml

helm upgrade --install promtail grafana/promtail \
  -n monitoring \
  -f /tmp/promtail-values.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Promtail deployed"
echo ""

# Wire Loki into Grafana as a datasource. kube-prometheus-stack's Grafana runs
# with the datasource sidecar enabled by default, watching for ConfigMaps
# labelled grafana_datasource=1 in this namespace.
echo -e "${BLUE}[5/6]${NC} Registering Loki as a Grafana datasource..."
cat > /tmp/loki-datasource.yaml <<'DS_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-grafana-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc.cluster.local:3100
      isDefault: false
DS_EOF
kubectl apply -f /tmp/loki-datasource.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Datasource ConfigMap applied"
echo ""

# Wait for rollout
echo -e "${BLUE}[6/6]${NC} Waiting for components to be ready..."
kubectl rollout status statefulset/loki -n monitoring --timeout=5m >> "$LOG_FILE" 2>&1
kubectl rollout status daemonset/promtail -n monitoring --timeout=5m >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} All components ready"
echo ""

echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Phase 2 Complete!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "Running pods:"
kubectl get pods -n monitoring -l 'app.kubernetes.io/name in (loki,promtail)' --no-headers | sed 's/^/  /'
echo ""

echo -e "${YELLOW}VERIFY:${NC}"
echo -e "  In Grafana (http://localhost:3000, admin / admin123):"
echo -e "  Explore → Loki → query: ${BLUE}{namespace=\"monitoring\"}${NC}"
echo -e "  Grafana may take a minute to pick up the new datasource (sidecar poll)."
echo ""
echo -e "${YELLOW}CLEANUP (Loki/Promtail only, keeps the cluster):${NC}"
echo -e "   ${BLUE}helm uninstall loki promtail -n monitoring${NC}"
echo ""
