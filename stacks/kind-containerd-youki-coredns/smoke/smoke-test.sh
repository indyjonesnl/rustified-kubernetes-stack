#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${KIND_NODE:-youki-control-plane}"
NS=smoke

cleanup() { kubectl delete namespace "$NS" --ignore-not-found --wait=false || true; }
trap cleanup EXIT

echo "==> Applying smoke manifests"
kubectl apply -f "$HERE/manifests.yaml"

echo "==> Waiting for Deployment to become available"
kubectl -n "$NS" wait --for=condition=Available deployment/web --timeout=120s

echo "==> Waiting for Jobs to complete"
kubectl -n "$NS" wait --for=condition=Complete job/pvc-writer --timeout=120s
kubectl -n "$NS" wait --for=condition=Complete job/dns-test --timeout=120s

echo "==> Asserting Service has endpoints (kube-proxy / endpoints controller)"
EP=$(kubectl -n "$NS" get endpoints web -o jsonpath='{.subsets[*].addresses[*].ip}')
test -n "$EP" || { echo "FAIL: web Service has no endpoints"; exit 1; }
echo "endpoints: $EP"

# Jobs can retry (backoffLimit) when DNS/PVC isn't ready on the first attempt, so
# the job ends up with several pods. `kubectl logs job/<name>` then picks an
# arbitrary (possibly failed) attempt. The job already reached condition=Complete
# above, so read the SUCCEEDED pod's log specifically — deterministic.
echo "==> Asserting CoreDNS resolved the Service (dns-test succeeded pod)"
DNS_POD=$(kubectl -n "$NS" get pods -l job-name=dns-test \
  --field-selector=status.phase=Succeeded -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
test -n "$DNS_POD" || { echo "FAIL: dns-test job has no Succeeded pod"; exit 1; }
kubectl -n "$NS" logs "$DNS_POD" | grep -q "web.smoke.svc.cluster.local" \
  || { echo "FAIL: DNS lookup did not resolve service name"; exit 1; }

echo "==> Asserting PVC write persisted (pvc-writer succeeded pod)"
PVC_POD=$(kubectl -n "$NS" get pods -l job-name=pvc-writer \
  --field-selector=status.phase=Succeeded -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
test -n "$PVC_POD" || { echo "FAIL: pvc-writer job has no Succeeded pod"; exit 1; }
kubectl -n "$NS" logs "$PVC_POD" | grep -q "persisted" \
  || { echo "FAIL: PVC marker not written"; exit 1; }

echo "==> Exec into a web pod: verify ConfigMap mount + Secret env (shim streaming)"
# A Running pod is execable even if readiness momentarily blips under load, so
# target phase=Running and retry generously rather than requiring ready==true.
cfg_ok=""
POD=""
for attempt in $(seq 1 10); do
  POD=$(kubectl -n "$NS" get pod -l app=web --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD" ] && kubectl -n "$NS" exec "$POD" -- cat /etc/appcfg/message 2>/dev/null | grep -q "hello-from-configmap"; then
    cfg_ok=1; break
  fi
  echo "   exec attempt $attempt did not succeed (pod=${POD:-none}), retrying..."; sleep 5
done
test -n "$cfg_ok" || { echo "FAIL: ConfigMap not mounted in pod"; exit 1; }
kubectl -n "$NS" exec "$POD" -- printenv APP_TOKEN 2>/dev/null | grep -q "s3cr3t-token" \
  || { echo "FAIL: Secret env not injected"; exit 1; }

echo "==> Verifying containers ran on the Rust shim + Youki"
SHIMS=$(docker exec "$NODE" ps aux | grep -c '[c]ontainerd-shim-runc-v2-rs' || true)
test "$SHIMS" -gt 0 || { echo "FAIL: no containerd-shim-runc-v2-rs processes found"; exit 1; }
echo "rust shim processes running: $SHIMS"

echo "PASS: kind-containerd-youki-coredns smoke test"
