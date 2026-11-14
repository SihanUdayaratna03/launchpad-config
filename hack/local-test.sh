#!/usr/bin/env bash
set -euo pipefail

CLUSTER=launchpad-test
NS=preview-pr-1
cd "$(dirname "$0")/.."

for t in docker k3d kubectl helm; do
  command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done

trap 'echo "== deleting cluster"; k3d cluster delete $CLUSTER >/dev/null 2>&1 || true' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }
FAILED=0

echo "== create k3d cluster"
k3d cluster create $CLUSTER --wait

echo "== install Kyverno 3.10.0"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno --version 3.10.0 -n kyverno --create-namespace \
  --set reportsController.enabled=false --set cleanupController.enabled=false --wait --timeout 5m
kubectl get pods -n kyverno

echo "== apply policies"
kubectl apply -f policies/

echo "== create labelled preview namespace and deploy the chart"
kubectl create namespace $NS
kubectl label namespace $NS launchpad.io/preview=true
helm template $NS charts/preview --set prNumber=1 -n $NS | kubectl apply -n $NS -f -

GOOD_SC='"securityContext":{"runAsNonRoot":true,"allowPrivilegeEscalation":false}'
RES='"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}'
GOOD_IMG=nginxinc/nginx-unprivileged:1.27-alpine

try_pod() {
  local name=$1 image=$2 container_extra=$3 spec_extra=${4:-}
  kubectl -n $NS run "$name" --image="$image" --dry-run=server \
    --overrides="{\"spec\":{${spec_extra:+$spec_extra,}\"containers\":[{\"name\":\"$name\",\"image\":\"$image\"${container_extra:+,$container_extra}}]}}" 2>&1
}

expect_denied() {
  local label=$1 fragment=$2 out
  shift 2
  if out=$(try_pod "$@"); then fail "$label was admitted"; return; fi
  if grep -q "$fragment" <<<"$out"; then pass "$label denied by Kyverno"; else fail "$label denied, but not by Kyverno: $out"; fi
}

echo "== wait for policies to be enforced"
for i in $(seq 1 30); do
  if try_pod probe $GOOD_IMG "$RES" 2>&1 | grep -q "runAsNonRoot"; then break; fi
  sleep 4
done

echo "== compliant pod runs"
if kubectl -n $NS rollout status deploy/$NS --timeout=180s; then pass "chart pod is admitted and ready"; else fail "chart pod did not become ready"; fi
if try_pod good $GOOD_IMG "$GOOD_SC,$RES" >/dev/null; then pass "a compliant pod is admitted"; else fail "a compliant pod was rejected"; fi

echo "== each policy denies exactly its own violation"
expect_denied "root user"          "runAsNonRoot"                      root-user  $GOOD_IMG "$RES"
expect_denied ":latest tag"        "explicit tag"                      latest-tag nginxinc/nginx-unprivileged:latest "$GOOD_SC,$RES"
expect_denied "unapproved image"   "Image must come from"              bad-image  busybox:1.36 "$GOOD_SC,$RES"
expect_denied "no resources"       "CPU and memory"                    no-limits  $GOOD_IMG "$GOOD_SC"
expect_denied "host network"       "Privileged containers and host"    host-net   $GOOD_IMG "$GOOD_SC,$RES" '"hostNetwork":true'

echo "== default namespace is untouched by the policies"
if kubectl -n default run free --image=nginx:latest --dry-run=server >/dev/null 2>&1; then pass "default namespace unaffected"; else fail "default namespace affected"; fi

echo "== NetworkPolicy"
SVC=$NS.$NS.svc.cluster.local
kubectl create namespace attacker >/dev/null
if kubectl -n attacker run curl --rm -i --restart=Never --image=busybox:1.36 -- wget -T 5 -qO- http://$SVC >/dev/null 2>&1; then
  fail "other namespace can reach the preview"
else pass "other namespace blocked"; fi

if kubectl -n kube-system run fake-traefik --rm -i --restart=Never --labels=app.kubernetes.io/name=traefik \
     --image=busybox:1.36 -- wget -T 5 -qO- http://$SVC >/dev/null 2>&1; then
  pass "traefik-labelled pod in kube-system can reach the preview"
else fail "traefik cannot reach the preview"; fi

POD=$(kubectl -n $NS get pod -l app=$NS -o name | head -1)
if kubectl -n $NS exec "$POD" -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
  pass "DNS egress allowed"; else fail "DNS egress blocked"; fi
if kubectl -n default run inet --rm -i --restart=Never --image=busybox:1.36 -- wget -T 5 -qO- http://1.1.1.1 >/dev/null 2>&1; then
  if kubectl -n $NS exec "$POD" -- wget -T 5 -qO- http://1.1.1.1 >/dev/null 2>&1; then
    fail "internet egress is open"; else pass "internet egress blocked (internet reachable from default)"; fi
else
  echo "  SKIP: no internet from the cluster, egress test is inconclusive"
fi

echo
if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
