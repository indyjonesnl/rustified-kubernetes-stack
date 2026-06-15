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

echo "==> Asserting CoreDNS resolved the Service (dns-test job log)"
kubectl -n "$NS" logs job/dns-test | grep -q "web.smoke.svc.cluster.local" \
  || { echo "FAIL: DNS lookup did not resolve service name"; exit 1; }

echo "==> Asserting PVC write persisted (pvc-writer job log)"
kubectl -n "$NS" logs job/pvc-writer | grep -q "persisted" \
  || { echo "FAIL: PVC marker not written"; exit 1; }

echo "==> Exec into a web pod: verify ConfigMap mount + Secret env (shim streaming)"
POD=$(kubectl -n "$NS" get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" exec "$POD" -- cat /etc/appcfg/message | grep -q "hello-from-configmap" \
  || { echo "FAIL: ConfigMap not mounted in pod"; exit 1; }
kubectl -n "$NS" exec "$POD" -- printenv APP_TOKEN | grep -q "s3cr3t-token" \
  || { echo "FAIL: Secret env not injected"; exit 1; }

echo "==> Verifying containers ran on the Rust shim + Youki"
SHIMS=$(docker exec "$NODE" ps aux | grep -c '[c]ontainerd-shim-runc-v2-rs')
test "$SHIMS" -gt 0 || { echo "FAIL: no containerd-shim-runc-v2-rs processes found"; exit 1; }
echo "rust shim processes running: $SHIMS"

echo "PASS: kind-containerd-youki-coredns smoke test"
