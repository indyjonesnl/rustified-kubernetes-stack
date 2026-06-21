#!/usr/bin/env bash
set -uo pipefail

PROFILE="k0s-rhino"
PROJECT="k0s-rhino"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$DIR/.." && pwd)"

kc() { docker exec k0s-rhino-cluster k0s kubectl "$@"; }

cleanup() { 
  echo "::group::cleanup"
  docker compose -p "$PROJECT" -f "$STACK_DIR/docker-compose.yml" down -v --remove-orphans || true
  echo "::endgroup::"
}

trap cleanup EXIT

fail() {
  echo "STACK FAIL: $*"
  echo "== nodes =="; kc get nodes -o wide 2>&1 | head
  echo "== pods =="; kc get pods -A 2>&1 | head -30
  exit 1
}

echo "::group::start k0s stack"
docker compose -p "$PROJECT" -f "$STACK_DIR/docker-compose.yml" up -d
echo "::endgroup::"

echo "::group::wait for node Ready"
ready=""
for i in $(seq 1 40); do
  [ "$(kc get nodes --no-headers 2>/dev/null | awk '{print $2}')" = "Ready" ] && { ready=1; break; }
  echo "Waiting for node Ready... ($i/40)"; sleep 10
done
[ "$ready" = 1 ] || fail "node never became Ready"
echo "::endgroup::"

echo "::group::repair coredns (forward->upstream; avoids plugin/loop crash) — idempotent"
if kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q '/etc/resolv.conf'; then
  NEWCORE="$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | sed 's#forward . /etc/resolv.conf#forward . 8.8.8.8 1.1.1.1#')"
  kc -n kube-system patch configmap coredns --type merge \
    -p "$(python3 -c 'import json,sys;print(json.dumps({"data":{"Corefile":sys.stdin.read()}}))' <<<"$NEWCORE")" >/dev/null 2>&1
  kc -n kube-system rollout restart deploy coredns >/dev/null 2>&1
fi
kc -n kube-system delete pods --field-selector status.phase=Failed >/dev/null 2>&1 || true
for i in $(seq 1 24); do
  [ "$(kc -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '{print $2}')" = "1/1" ] && break
  sleep 5
done
echo "::endgroup::"

echo "::group::verify rhino is the datastore"
# The apiserver must be pointed at rhino (external etcd), not embedded.
docker exec k0s-rhino-cluster sh -c 'cat /proc/*/cmdline 2>/dev/null | tr "\0" "\n" | grep -m1 "etcd-servers=.*172.31.7.10:2379"' >/dev/null 2>&1 \
  && echo "apiserver --etcd-servers points at rhino (172.31.7.10:2379)" \
  || fail "apiserver is not using rhino as etcd"
echo "::endgroup::"

echo "::group::smoke: Deployment + Service + DNS"
kc create namespace smoke >/dev/null 2>&1 || true
kc apply -f "$DIR/manifests.yaml"
kc -n smoke rollout status deployment/web --timeout=180s || fail "web Deployment not available"
echo "web Running"

# DNS test
kc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: { name: dns-test, namespace: smoke }
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: dns
        image: busybox:1.36
        command: ["sh","-c","for i in $(seq 1 20); do nslookup web.smoke.svc.cluster.local && exit 0; sleep 3; done; exit 1"]
EOF
kc -n smoke wait --for=condition=complete job/dns-test --timeout=150s || fail "DNS test did not resolve"
echo "DNS resolved"
echo "::endgroup::"

echo "PASS: k0s-rhino smoke test"
