#!/bin/bash
set -e

echo -e "╔════════════════════════════════════════════════════════════════╗"
echo -e "║  Phase 3: Sample App - Metrics + Logs Correlation             ║"
echo -e "║  Requires Phase 1 (setup.sh); Phase 2 optional for logs       ║"
echo -e "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CLUSTER_NAME="reliability-lab"
DEMO_NS="demo"
LOG_FILE="/tmp/reliability-lab-phase3.log"
: > "$LOG_FILE"
trap 'echo -e "\n❌ Setup failed. Last lines of $LOG_FILE:"; tail -n 30 "$LOG_FILE"' ERR

# Check prerequisites
echo -e "${BLUE}[1/6]${NC} Checking prerequisites..."
for cmd in kind kubectl docker; do
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
LOGS_AVAILABLE=true
if ! kubectl get daemonset/promtail -n monitoring >> "$LOG_FILE" 2>&1; then
    LOGS_AVAILABLE=false
    echo -e "${YELLOW}⚠${NC}  Promtail not found (Phase 2 not deployed) - metrics will work, log correlation will not"
fi
echo -e "${GREEN}✓${NC} All prerequisites found"
echo ""

# Namespace
echo -e "${BLUE}[2/6]${NC} Creating '$DEMO_NS' namespace..."
kubectl create namespace "$DEMO_NS" --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Namespace ready"
echo ""

# The sample app itself: stdlib-only Python so it needs no image build, no
# pip install, and no registry push - just python:3.12-slim + a ConfigMap.
# It exposes a hand-rolled /metrics endpoint (Prometheus text format) and logs
# every request as a JSON line to stdout, which Promtail (if deployed) picks
# up automatically since it tails every pod in the cluster.
echo -e "${BLUE}[3/6]${NC} Creating sample app source (ConfigMap)..."
cat > /tmp/demo-app-code.yaml <<'CODE_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-app-code
  namespace: demo
data:
  app.py: |
    import http.server, socketserver, threading, time, json, sys

    counts = {"total": 0, "errors": 0}
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass  # replaced by explicit structured logging below

        def _log(self, level, msg):
            print(json.dumps({
                "ts": time.time(), "level": level, "path": self.path, "msg": msg
            }))
            sys.stdout.flush()

        def do_GET(self):
            with lock:
                counts["total"] += 1
            if self.path == "/metrics":
                body = (
                    "# HELP demo_requests_total Total HTTP requests received\n"
                    "# TYPE demo_requests_total counter\n"
                    f"demo_requests_total {counts['total']}\n"
                    "# HELP demo_errors_total Total error (500) responses\n"
                    "# TYPE demo_errors_total counter\n"
                    f"demo_errors_total {counts['errors']}\n"
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/error":
                with lock:
                    counts["errors"] += 1
                self._log("error", "simulated failure")
                self.send_response(500)
                self.end_headers()
            else:
                self._log("info", "ok")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok\n")

    if __name__ == "__main__":
        with socketserver.ThreadingTCPServer(("0.0.0.0", 8080), Handler) as httpd:
            httpd.serve_forever()
CODE_EOF
kubectl apply -f /tmp/demo-app-code.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Source loaded"
echo ""

# Deployment + Service for the app
echo -e "${BLUE}[4/6]${NC} Deploying sample app..."
cat > /tmp/demo-app.yaml <<'APP_EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo
  labels:
    app: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
      - name: demo-app
        image: python:3.12-slim
        command: ["python3", "/app/app.py"]
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: code
          mountPath: /app
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
      volumes:
      - name: code
        configMap:
          name: demo-app-code
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo
  labels:
    app: demo-app
spec:
  selector:
    app: demo-app
  ports:
  - name: http
    port: 8080
    targetPort: 8080
APP_EOF
kubectl apply -f /tmp/demo-app.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} Sample app deployed"
echo ""

# ServiceMonitor so Prometheus auto-discovers it. kube-prometheus-stack was
# installed in Phase 1 with serviceMonitorSelectorNilUsesHelmValues: false,
# which makes the operator watch ServiceMonitors in every namespace - no
# special labels needed on this one.
echo -e "${BLUE}[5/6]${NC} Registering ServiceMonitor + load generator..."
cat > /tmp/demo-servicemonitor.yaml <<'SM_EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: demo-app
  namespace: demo
  labels:
    app: demo-app
spec:
  selector:
    matchLabels:
      app: demo-app
  endpoints:
  - port: http
    path: /metrics
    interval: 15s
SM_EOF
kubectl apply -f /tmp/demo-servicemonitor.yaml >> "$LOG_FILE" 2>&1

# Load generator: a busybox loop hitting the app so there's something to see
# on a dashboard, plus an occasional hit to /error to exercise the error path.
cat > /tmp/demo-loadgen.yaml <<'LG_EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-loadgen
  namespace: demo
  labels:
    app: demo-loadgen
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-loadgen
  template:
    metadata:
      labels:
        app: demo-loadgen
    spec:
      containers:
      - name: loadgen
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          while true; do
            wget -q -O- http://demo-app.demo.svc.cluster.local:8080/ >/dev/null 2>&1
            if [ $((RANDOM % 5)) -eq 0 ]; then
              wget -q -O- http://demo-app.demo.svc.cluster.local:8080/error >/dev/null 2>&1
            fi
            sleep 1
          done
LG_EOF
kubectl apply -f /tmp/demo-loadgen.yaml >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} ServiceMonitor + load generator deployed"
echo ""

# Wait for rollout
echo -e "${BLUE}[6/6]${NC} Waiting for components to be ready..."
kubectl rollout status deployment/demo-app -n "$DEMO_NS" --timeout=3m >> "$LOG_FILE" 2>&1
kubectl rollout status deployment/demo-loadgen -n "$DEMO_NS" --timeout=3m >> "$LOG_FILE" 2>&1
echo -e "${GREEN}✓${NC} All components ready"
echo ""

echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Phase 3 Complete!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "Running pods:"
kubectl get pods -n "$DEMO_NS" --no-headers | sed 's/^/  /'
echo ""

echo -e "${YELLOW}VERIFY:${NC}"
echo -e "  Prometheus Targets: http://localhost:9090/targets (look for job=demo-app)"
echo -e "  PromQL:  ${BLUE}rate(demo_requests_total[1m])${NC}"
echo -e "           ${BLUE}rate(demo_errors_total[1m])${NC}"
if [ "$LOGS_AVAILABLE" = true ]; then
echo -e "  Grafana Explore -> Loki -> ${BLUE}{namespace=\"demo\"}${NC} to see the matching request logs"
else
echo -e "  (Log correlation skipped - run ./setup-phase2.sh to add Loki/Promtail)"
fi
echo ""
echo -e "${YELLOW}CLEANUP (this phase only, keeps the cluster):${NC}"
echo -e "   ${BLUE}kubectl delete namespace demo${NC}"
echo ""
