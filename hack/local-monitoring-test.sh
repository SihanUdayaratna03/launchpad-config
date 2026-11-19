#!/usr/bin/env bash
set -euo pipefail

CLUSTER=launchpad-monitoring
cd "$(dirname "$0")/.."

for t in docker k3d kubectl helm python3; do
  command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done

trap 'echo "== deleting cluster"; k3d cluster delete $CLUSTER >/dev/null 2>&1 || true' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }
FAILED=0

# Keep these in step with argocd/prometheus.yaml and argocd/grafana.yaml.
PROM_VERSION=29.6.0
GRAFANA_VERSION=10.5.14

prom() {
  local q
  q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=$q" 2>/dev/null || true
}

expect_series() {
  local label=$1 query=$2 out=""
  for i in $(seq 1 30); do
    out=$(prom "$query")
    if grep -q '"result":\[{' <<<"$out"; then pass "$label"; return; fi
    sleep 5
  done
  fail "$label (query: $query, last answer: $out)"
}

echo "== create k3d cluster"
k3d cluster create $CLUSTER --wait

echo "== a labelled preview namespace and a stand-in controller that serves /metrics"
kubectl create namespace preview-pr-1
kubectl label namespace preview-pr-1 launchpad.io/preview=true
kubectl create namespace argocd
kubectl -n argocd apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: launchpad-controller-standin
  labels:
    app: launchpad-controller
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8090"
    prometheus.io/path: /metrics
spec:
  containers:
    - name: metrics
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          while true; do
            printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nConnection: close\r\n\r\n# TYPE launchpad_webhook_requests_total counter\nlaunchpad_webhook_requests_total{result="accepted"} 3\n' | nc -l -p 8090 >/dev/null
          done
YAML

echo "== install Prometheus $PROM_VERSION and Grafana $GRAFANA_VERSION with the same values Argo CD uses"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install prometheus prometheus-community/prometheus --version $PROM_VERSION \
  -n monitoring --create-namespace -f monitoring/prometheus-values.yaml --wait --timeout 6m
helm upgrade --install grafana grafana/grafana --version $GRAFANA_VERSION \
  -n monitoring -f monitoring/grafana-values.yaml --wait --timeout 6m
kubectl apply -f monitoring/dashboards/
kubectl -n monitoring get pods

echo "== Prometheus"
for i in $(seq 1 30); do
  kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- wget -qO- http://localhost:9090/-/ready >/dev/null 2>&1 && break
  sleep 3
done
if kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- wget -qO- http://localhost:9090/api/v1/rules 2>/dev/null | grep -q LaunchpadControllerDown; then
  pass "alert rules are loaded"; else fail "alert rules are not loaded"; fi
expect_series "kube-state-metrics is scraped"            'up{job=~"kubernetes-service-endpoints|kube-state-metrics"} == 1'
expect_series "the preview namespace is visible"         'kube_namespace_created{namespace="preview-pr-1"}'
expect_series "cAdvisor container metrics are scraped"   'container_memory_working_set_bytes{namespace="kube-system",container!=""}'
expect_series "the annotated controller pod is scraped"  'up{app="launchpad-controller"} == 1'
expect_series "the controller's own metric arrives"      'launchpad_webhook_requests_total{result="accepted"}'

echo "== Grafana"
PW=$(kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)
AUTH=$(printf 'admin:%s' "$PW" | base64 | tr -d '\n')
graf() {
  kubectl -n monitoring exec deploy/grafana -c grafana -- \
    wget -qO- --header "Authorization: Basic $AUTH" "http://localhost:3000$1" 2>/dev/null || true
}
out=""
for i in $(seq 1 30); do
  out=$(graf "/api/search?query=Launchpad")
  grep -q '"title":"Launchpad"' <<<"$out" && break
  sleep 4
done
if grep -q '"title":"Launchpad"' <<<"$out"; then pass "the Launchpad dashboard is loaded from its ConfigMap"; else fail "dashboard not found: $out"; fi
if graf "/api/datasources/uid/prometheus/health" | grep -q '"status":"OK"'; then pass "Grafana reaches Prometheus"; else fail "Grafana cannot reach Prometheus"; fi

if [ "$FAILED" != 0 ]; then
  echo
  echo "== diagnostics"
  kubectl -n argocd get pod launchpad-controller-standin -o wide --show-labels || true
  kubectl -n argocd logs launchpad-controller-standin --tail=5 || true
  echo "-- scrape jobs and health"
  prom 'count by (job, health) (up)' || true
  echo
  echo "-- targets for the stand-in"
  kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
    wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)["data"]
for t in d["activeTargets"]:
    print(t["labels"].get("job"), t["health"], t["scrapeUrl"], (t.get("lastError") or "")[:120])
print("dropped:", len(d["droppedTargets"]))
for t in d["droppedTargets"]:
    l=t.get("discoveredLabels",{})
    if l.get("__meta_kubernetes_pod_name","").startswith("launchpad"):
        print("DROPPED", t.get("discoveredLabels",{}).get("job"), l.get("__meta_kubernetes_pod_name"), l.get("__address__"))' || true
fi

echo
if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
