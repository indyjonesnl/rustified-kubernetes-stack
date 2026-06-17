#!/usr/bin/env bash
# Upstream Kubernetes on cri-dockerd+Docker (minikube). Baseline for the CRI path:
# kubelet -> CRI -> CRI-O -> crun/runc. Smoke: Deployment + Service + DNS, and verify
# the node's container runtime really is cri-dockerd+Docker.
set -uo pipefail

PROFILE="${PROFILE:-k8s-cridockerd}"
kc() { minikube -p "$PROFILE" kubectl -- "$@"; }

cleanup() { minikube delete -p "$PROFILE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() {
  echo "STACK FAIL: $*"
  echo "== nodes =="; kc get nodes -o wide 2>&1 | head
  echo "== pods =="; kc get pods -A 2>&1 | head -30
  echo "== dns-test logs =="; kc -n smoke logs job/dns-test 2>&1 | tail -15
  exit 1
}

echo "::group::start minikube (cri-dockerd + Docker)"
minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
minikube start -p "$PROFILE" --driver=docker --container-runtime=docker --wait=all --interactive=false || fail "minikube start"
echo "::endgroup::"

echo "::group::verify node container runtime is cri-dockerd+Docker"
rt=$(kc get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}')
echo "containerRuntimeVersion=$rt"
echo "$rt" | grep -qiE 'docker' || fail "node runtime is not docker/cri-dockerd: $rt"
echo "::endgroup::"

echo "::group::smoke: Deployment + Service + DNS"
kc create namespace smoke >/dev/null 2>&1 || true
kc apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, namespace: smoke }
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports: [ { containerPort: 80 } ]
EOF
kc -n smoke expose deployment web --port=80 >/dev/null
kc -n smoke rollout status deployment/web --timeout=120s || fail "web Deployment not available"
echo "web Running"
# DNS via CoreDNS (minikube default): a Job that resolves the Service FQDN.
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
kc -n smoke wait --for=condition=complete job/dns-test --timeout=120s || fail "DNS test did not resolve via CoreDNS"
echo "DNS resolved via CoreDNS"
echo "::endgroup::"

echo "PASS: kubernetes-cridockerd-docker smoke test"
