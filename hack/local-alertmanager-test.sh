#!/usr/bin/env bash
# Check, on a throwaway k3d cluster, that an alert actually travels the whole way:
#
#   a rule fires  ->  Prometheus hands it to Alertmanager  ->  Alertmanager sends it to Discord
#
# No controller is installed, so the LaunchpadControllerDown rule fires on its own
# after two minutes. That is the alert this script follows.
#
# With DISCORD_WEBHOOK set to a real webhook URL, the last step is checked too and a
# message appears in that channel. Without it, the run stops at Alertmanager and says so.
#
#   DISCORD_WEBHOOK='https://discord.com/api/webhooks/...' ./hack/local-alertmanager-test.sh
#
# Needs: k3d, kubectl, helm, curl. Takes about six minutes, most of it waiting for
# the alert's "for: 2m" to elapse.
set -euo pipefail

CLUSTER=${CLUSTER:-launchpad-alerts}
RELEASE=prometheus
NS=monitoring
CHART_VERSION=29.6.0
WAIT=${WAIT:-360}

cd "$(dirname "$0")/.."

for t in k3d kubectl helm curl; do
  command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done

FAILED=0
PF_AM=
PF_PROM=
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

cleanup() {
  [ -n "$PF_AM" ] && kill "$PF_AM" 2>/dev/null || true
  [ -n "$PF_PROM" ] && kill "$PF_PROM" 2>/dev/null || true
  echo "== deleting cluster"
  k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# wait_for SECONDS COMMAND...: poll until the command succeeds.
wait_for() {
  local limit=$1 i=0; shift
  until "$@" >/dev/null 2>&1; do
    i=$((i + 5)); [ "$i" -ge "$limit" ] && return 1; sleep 5
  done
}

alert_firing()   { curl -sf --max-time 5 localhost:9093/api/v2/alerts | grep -q LaunchpadControllerDown; }
prom_sees_am()   { curl -sf --max-time 5 localhost:9090/api/v1/alertmanagers | grep -q '"activeAlertmanagers":\[{'; }
# metric NAME: the counter's value, or 0 when Alertmanager has not published it yet.
metric() { curl -sf --max-time 5 localhost:9093/metrics | awk -v n="$1" '$0 ~ "^"n"{" && /integration="discord"/ {v=$2} END {print v+0}'; }

echo "== creating cluster $CLUSTER"
k3d cluster create "$CLUSTER" --wait >/dev/null

# k3d returns as soon as the server container is up, which is a little before the
# API server answers reliably. Everything after this talks to that API, so wait.
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null || {
  echo "the cluster never became ready:"; kubectl get nodes; docker ps -a --filter name=k3d-$CLUSTER; exit 1; }
wait_for 60 kubectl get --raw /readyz || { echo "the API server never reported ready"; exit 1; }

kubectl create namespace "$NS" >/dev/null

if [ -n "${DISCORD_WEBHOOK:-}" ]; then
  echo "== Discord webhook provided, delivery will be checked"
  kubectl -n "$NS" create secret generic alertmanager-discord \
    --from-literal=webhook-url="$DISCORD_WEBHOOK" >/dev/null
else
  echo "== DISCORD_WEBHOOK is not set: checking as far as Alertmanager only"
  kubectl -n "$NS" create secret generic alertmanager-discord \
    --from-literal=webhook-url="https://discord.com/api/webhooks/0/not-a-real-webhook" >/dev/null
fi

echo "== installing prometheus $CHART_VERSION with the repository's values"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
install() {
  helm install "$RELEASE" prometheus-community/prometheus --version "$CHART_VERSION" \
    -n "$NS" -f monitoring/prometheus-values.yaml --wait --timeout 6m
}
if ! install >/dev/null; then
  echo "   first attempt failed, retrying once"
  helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
  sleep 10
  if ! install; then
    echo "== install failed twice; what the cluster looks like:"
    kubectl get nodes -o wide || true
    kubectl -n "$NS" get pods || true
    docker ps -a --filter "name=k3d-$CLUSTER" --format '{{.Names}}\t{{.Status}}' || true
    exit 1
  fi
fi

echo "== alertmanager is part of the release"
kubectl -n "$NS" get sts "$RELEASE-alertmanager" >/dev/null 2>&1 \
  && pass "Alertmanager StatefulSet exists" || fail "no Alertmanager StatefulSet"

kubectl -n "$NS" get sts "$RELEASE-alertmanager" \
  -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' 2>/dev/null \
  | grep -q /etc/alertmanager-secrets \
  && pass "the Discord secret is mounted, not baked into the config" \
  || fail "the Discord secret is not mounted"

kubectl -n "$NS" get cm "$RELEASE-alertmanager" -o yaml 2>/dev/null | grep -q "discord.com/api/webhooks" \
  && fail "the webhook URL leaked into the ConfigMap" \
  || pass "no webhook URL in the ConfigMap"

kubectl -n "$NS" port-forward "svc/$RELEASE-alertmanager" 9093:9093 >/dev/null 2>&1 &
PF_AM=$!
kubectl -n "$NS" port-forward "svc/$RELEASE-server" 9090:80 >/dev/null 2>&1 &
PF_PROM=$!
wait_for 60 curl -sf --max-time 5 localhost:9093/-/ready || { echo "Alertmanager never became ready"; exit 1; }
wait_for 60 curl -sf --max-time 5 localhost:9090/-/ready || { echo "Prometheus never became ready"; exit 1; }

echo "== prometheus found alertmanager"
wait_for 60 prom_sees_am \
  && pass "Prometheus is sending alerts to Alertmanager" \
  || fail "Prometheus has no active Alertmanager"

echo "== waiting up to ${WAIT}s for LaunchpadControllerDown to fire"
wait_for "$WAIT" alert_firing \
  && pass "the alert reached Alertmanager" \
  || fail "the alert never reached Alertmanager within ${WAIT}s"

if [ -n "${DISCORD_WEBHOOK:-}" ]; then
  echo "== delivery to Discord"
  wait_for 120 test "$(metric alertmanager_notifications_total)" -gt 0 \
    && pass "Alertmanager sent a Discord notification" \
    || fail "Alertmanager never sent a Discord notification"
  if [ "$(metric alertmanager_notifications_failed_total)" -eq 0 ]; then
    pass "Discord accepted it (no failed notifications)"
  else
    fail "Discord rejected it: $(metric alertmanager_notifications_failed_total) failed notifications"
  fi
  echo "  (check the channel: a LaunchpadControllerDown message should be there)"
else
  echo "  SKIP: delivery to Discord, DISCORD_WEBHOOK is not set"
fi

echo
if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAILED"
