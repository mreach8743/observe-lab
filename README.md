# Observability Lab

A local Kubernetes (kind) reliability/observability lab, built in phases.

## Prerequisites

- Docker (running)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/)

## Phases

Run in order. Each script is idempotent and safe to re-run.

### Phase 1 — Metrics Foundation (`setup.sh`)

Creates a kind cluster (`reliability-lab`) and deploys the
`kube-prometheus-stack` (Prometheus, Grafana, Alertmanager) via Helm into the
`monitoring` namespace, plus a few custom alert rules.

```bash
./setup.sh
```

- Prometheus: `kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090` → http://localhost:9090
- Grafana: `kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80` → http://localhost:3000 (`admin` / `admin123`)

### Phase 2 — Logging (`setup-phase2.sh`)

Adds Loki (single-binary, filesystem storage) and Promtail (DaemonSet) into
the same `monitoring` namespace, and registers Loki as a Grafana datasource.
Requires Phase 1.

```bash
./setup-phase2.sh
```

- Explore logs in Grafana: **Explore → Loki** → `{namespace="monitoring"}`

### Phase 3 — Sample App (`setup-phase3.sh`)

Deploys a small stdlib-only Python HTTP app (in a new `demo` namespace) that
exposes a `/metrics` endpoint and structured JSON logs, plus a load generator
that exercises it (including an `/error` path). A `ServiceMonitor` lets
Prometheus auto-discover it with no manual scrape config. Requires Phase 1;
Phase 2 is optional (used for log correlation).

```bash
./setup-phase3.sh
```

- Metrics: `rate(demo_requests_total[1m])`, `rate(demo_errors_total[1m])`
- Logs: **Explore → Loki** → `{namespace="demo"}`

## Cleanup

```bash
kubectl delete namespace demo                # Phase 3 only
helm uninstall loki promtail -n monitoring    # Phase 2 only
kind delete cluster --name reliability-lab    # everything
```
