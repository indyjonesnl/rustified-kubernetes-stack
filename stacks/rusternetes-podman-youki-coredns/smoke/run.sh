#!/usr/bin/env bash
# Bring up the Rusternetes all-in-one on rootful podman+youki with CoreDNS, then
# smoke-test Deployment + Service + DNS and verify pods ran on youki. One process.
set -uo pipefail

YOUKI=/usr/local/bin/youki
SOCK=/run/podman/podman.sock
RKT_LOG=/tmp/rusternetes.log
SRC="$(cat "$(dirname "$0")/../.rusternetes-src-path" 2>/dev/null || echo ../rusternetes)"
KBIN="$SRC/target/release/kubectl"
kctl() { "$KBIN" --insecure-skip-tls-verify "$@"; }

cleanup() {
  sudo pkill -f 'target/release/rusternetes' 2>/dev/null || true
  for p in $(sudo podman pod ls -q 2>/dev/null); do sudo podman pod rm -f "$p" 2>/dev/null || true; done
}
trap cleanup EXIT
diag() {
  echo "== rusternetes log =="; sudo tail -120 "$RKT_LOG" 2>/dev/null
  echo "== pods =="; kctl get pods -A 2>&1 | head -40
  echo "== describe web =="; kctl describe pod -n smoke web 2>&1 | tail -30
  echo "== dns-test logs =="; kctl logs dns-test -n smoke 2>&1 | tail -20
}
fail() { echo "STACK FAIL: $*"; diag; exit 1; }

echo "::group::start rootful podman socket"
sudo mkdir -p /run/podman
sudo podman system service --time=0 "unix://$SOCK" &>/tmp/podman-service.log &
for i in $(seq 1 15); do sudo test -S "$SOCK" && break; sleep 1; done
sudo test -S "$SOCK" || { sudo cat /tmp/podman-service.log; exit 1; }
echo "::endgroup::"

echo "::group::start all-in-one (rootful, netstack, SQLite)"
( cd "$SRC" && bash scripts/generate-certs.sh )
sudo env DOCKER_HOST="unix://$SOCK" "$SRC/target/release/rusternetes" \
  --data-dir "$SRC/cluster.db" --storage-backend sqlite --bind-address 0.0.0.0:6443 --tls \
  --tls-cert-file "$SRC/.rusternetes/certs/api-server.crt" --tls-key-file "$SRC/.rusternetes/certs/api-server.key" \
  --node-name node-1 --volume-dir "$SRC/.rusternetes/volumes" --pod-network-mode netstack &>"$RKT_LOG" &
ok=""
for i in $(seq 1 60); do curl -sfk https://localhost:6443/healthz >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || fail "apiserver not healthy"
echo "apiserver healthy"
echo "::endgroup::"

echo "::group::bootstrap CoreDNS (USE_RUSTERNETES_DNS=0)"
# Runner has both docker+podman; bootstrap refuses to guess -> pass CONTAINER_RUNTIME.
( cd "$SRC" && KUBECTL="$KBIN" USE_RUSTERNETES_DNS=0 CONTAINER_RUNTIME=podman bash scripts/bootstrap-cluster.sh ) \
  || echo "(bootstrap returned nonzero; continuing to readiness check)"
dns=""
for i in $(seq 1 40); do kctl get pods -n kube-system 2>/dev/null | grep -qi 'coredns.*Running' && { dns=1; break; }; sleep 3; done
[ "$dns" = 1 ] || fail "CoreDNS not Running after bootstrap"
echo "CoreDNS Running"
echo "::endgroup::"

echo "::group::smoke: Deployment + Service + DNS"
kctl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata: { name: smoke }
EOF
kctl apply -f - <<'EOF'
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
        image: docker.io/library/nginx:1.27-alpine
        ports: [ { containerPort: 80 } ]
EOF
kctl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata: { name: web, namespace: smoke }
spec:
  selector: { app: web }
  ports: [ { port: 80, targetPort: 80 } ]
EOF
web=""
for i in $(seq 1 60); do kctl get pods -n smoke 2>/dev/null | grep -q 'web.*Running' && { web=1; break; }; sleep 3; done
[ "$web" = 1 ] || fail "web pod not Running"
echo "web Running"
kctl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: dns-test, namespace: smoke }
spec:
  restartPolicy: Never
  containers:
  - name: dns
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","for i in $(seq 1 20); do nslookup web.smoke.svc.cluster.local && exit 0; sleep 3; done; exit 1"]
EOF
dnsok=""
for i in $(seq 1 50); do
  st=$(kctl get pods -n smoke 2>/dev/null | grep dns-test); echo "dns-test: ${st:-<none>}"
  echo "$st" | grep -qiE 'Succeeded|Completed' && { dnsok=1; break; }
  echo "$st" | grep -qi 'Failed' && break
  sleep 3
done
[ "$dnsok" = 1 ] || fail "DNS test pod did not Succeed (CoreDNS resolution)"
echo "DNS resolved via CoreDNS"
echo "::endgroup::"

echo "::group::verify pods ran on youki"
cid=$(sudo podman ps --format '{{.ID}} {{.Names}}' | grep -iE 'web|nginx' | awk '{print $1}' | head -1)
[ -n "$cid" ] || fail "no web container in podman"
rt=$(sudo podman inspect "$cid" --format '{{.OCIRuntime}}'); echo "OCIRuntime=$rt"
echo "$rt" | grep -qi youki || fail "OCIRuntime not youki: $rt"
echo "::endgroup::"

echo "PASS: rusternetes-podman-youki-coredns smoke test"
