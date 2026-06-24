#!/usr/bin/env bash
# Smoke test for k0s-rhino-crun-flannelrs: k8s v1.35 with rhino datastore, crun OCI
# runtime, and flannel-rs CNI. Brings the stack up, deploys flannel-rs (provider=custom
# ships no CNI), and verifies a Deployment+Service+DNS plus that pods run on crun.
set -uo pipefail

PROJECT="k0s-rhino-cdrsfl"
NODE_CTR="k0s-rhino-cdrsfl-cluster"
RHINO_IP="172.33.7.10"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$DIR/.." && pwd)"

# -i so `kc apply -f -` can read manifests from stdin (the in-container kubectl
# cannot see host file paths).
kc() { docker exec -i "$NODE_CTR" k0s kubectl "$@"; }

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
docker compose -p "$PROJECT" -f "$STACK_DIR/docker-compose.yml" up -d --build
echo "::endgroup::"

echo "::group::deploy flannel-rs CNI (provider=custom ships none)"
for _ in $(seq 1 48); do kc get --raw=/healthz >/dev/null 2>&1 && break; sleep 5; done
NODE="$(kc get nodes --no-headers 2>/dev/null | awk '{print $1}' | head -1)"
if [ -n "$NODE" ] && [ -z "$(kc get node "$NODE" -o jsonpath='{.spec.podCIDR}' 2>/dev/null)" ]; then
  kc patch node "$NODE" -p '{"spec":{"podCIDR":"10.244.0.0/24","podCIDRs":["10.244.0.0/24"]}}' >/dev/null 2>&1
fi
kc apply -f - < "$STACK_DIR/flannel-rs.yaml" >/dev/null 2>&1 || fail "apply flannel-rs"
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

echo "::group::verify rhino datastore + containerd-rs CRI + crun OCI runtime"
docker exec "$NODE_CTR" sh -c "cat /proc/*/cmdline 2>/dev/null | tr '\0' '\n' | grep -m1 'etcd-servers=.*$RHINO_IP:2379'" >/dev/null 2>&1 \
  && echo "apiserver --etcd-servers points at rhino ($RHINO_IP:2379)" \
  || fail "apiserver is not using rhino as etcd"
# The CRI is containerd-rs: the kubelet reports the runtime name+version from the
# CRI Version RPC in Node.status.nodeInfo.containerRuntimeVersion.
NODE="$(kc get nodes --no-headers 2>/dev/null | awk '{print $1}' | head -1)"
crv="$(kc get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null)"
echo "containerRuntimeVersion: $crv"
case "$crv" in *containerd-rs*) echo "CRI is containerd-rs ($crv)";; *) fail "CRI is not containerd-rs (got '$crv')";; esac
# crun is the OCI runtime; containerd-rs keeps crun state under /var/run/containerd-rs/crun.
crun_running="$(docker exec "$NODE_CTR" sh -c 'crun --root /var/run/containerd-rs/crun list 2>/dev/null | grep -c running')"
[ "${crun_running:-0}" -ge 1 ] && echo "crun is the OCI runtime ($crun_running running containers)" \
  || fail "crun is not running any containers (OCI runtime not crun)"
echo "::endgroup::"

echo "::group::smoke: Deployment + Service + DNS"
kc create namespace smoke >/dev/null 2>&1 || true
kc apply -f - < "$DIR/manifests.yaml"
kc -n smoke rollout status deployment/web --timeout=180s || fail "web Deployment not available"
echo "web Running"

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

echo "::group::verify flannel-rs pod networking (pod IP in 10.244/16)"
podip="$(kc -n smoke get pods -l app=web -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)"
echo "web pod IP: $podip"
case "$podip" in 10.244.*) echo "pod IP is in the flannel-rs pod CIDR";; *) fail "pod IP '$podip' not in 10.244/16 (CNI fell back to host net?)";; esac
echo "::endgroup::"

echo "PASS: k0s-rhino-containerdrs-crun-flannelrs smoke (rhino datastore + containerd-rs CRI + crun OCI + flannel-rs CNI)"
