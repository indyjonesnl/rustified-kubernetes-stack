#!/usr/bin/env bash
# Bring up the Rusternetes all-in-one on rootful podman+youki with the in-process
# rusternetes-dns (NOT CoreDNS), then smoke-test Deployment + Service + DNS and verify
# pods ran on youki. One process.
set -uo pipefail

YOUKI=/usr/local/bin/youki
# Dedicated socket path: /run/podman/podman.sock may already exist (e.g. a systemd
# podman socket dir) and collide ("Error: is a directory").
SOCK=/run/podman/rkt-youki.sock
RKT_LOG=/tmp/rusternetes.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cat "$SCRIPT_DIR/../.rusternetes-src-path" 2>/dev/null || true)"
if [ -z "$SRC" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  SRC="$(cd "$REPO_ROOT/../rusternetes" 2>/dev/null && pwd || echo "$REPO_ROOT/.rusternetes-src")"
fi
KBIN="$SRC/target/release/kubectl"
KCFG=/tmp/rkt-youki-kubeconfig   # generated after the apiserver is up; KUBECONFIG points here
# KUBECONFIG (set later) silences the "could not load kubeconfig" warning; the flag
# forces skip-verify so the in-tree kubectl (rustls) doesn't reject the self-signed
# CA:TRUE api-server cert as a leaf ("CaUsedAsEndEntity"). This matches test-cluster.sh.
kctl() { "$KBIN" --insecure-skip-tls-verify "$@"; }

cleanup() {
  sudo pkill -f 'target/release/rusternetes' 2>/dev/null || true
  sudo pkill -f 'podman system service.*rkt-youki' 2>/dev/null || true
  sudo podman rm -f rkt-netkeeper 2>/dev/null || true
  for p in $(sudo podman pod ls -q 2>/dev/null); do sudo podman pod rm -f "$p" 2>/dev/null || true; done
  stty sane 2>/dev/null || true   # restore terminal if a child left it in raw mode
}
trap cleanup EXIT
diag() {
  echo "== rusternetes log =="; sudo tail -120 "$RKT_LOG" 2>/dev/null
  echo "== pods =="; kctl get pods -A 2>&1 | head -40
  echo "== describe web =="; kctl describe pod -n smoke web 2>&1 | tail -30
  echo "== dns-test logs =="; kctl logs dns-test -n smoke 2>&1 | tail -20
  echo "== rusternetes-dns server lines =="; sudo grep -iE 'rusternetes_dns|dns server|serving zone|:53|cannot assign|address already in use' "$RKT_LOG" 2>/dev/null | head -15
}
fail() { echo "STACK FAIL: $*"; diag; exit 1; }

echo "::group::pre-clean stale state from prior local runs (CI is always fresh)"
sudo pkill -9 -f 'target/release/rusternetes' 2>/dev/null || true
sudo pkill -9 -f 'podman system service.*rkt-youki' 2>/dev/null || true
# Wait for :6443 to actually be released before starting (avoid "Address already in use").
for i in $(seq 1 15); do ss -ltn 2>/dev/null | grep -q ':6443 ' || break; echo "  waiting for :6443 to free..."; sleep 1; done
sudo rm -f "$SRC/cluster.db" "$SRC/cluster.db-shm" "$SRC/cluster.db-wal"
for p in $(sudo podman pod ls -q 2>/dev/null); do sudo podman pod rm -f "$p" 2>/dev/null || true; done
sudo podman rm -af 2>/dev/null || true
echo "::endgroup::"

echo "::group::start rootful podman socket"
sudo mkdir -p /run/podman
sudo rm -f "$SOCK" 2>/dev/null || true
sudo podman system service --time=0 "unix://$SOCK" </dev/null &>/tmp/podman-service.log &
for i in $(seq 1 15); do sudo test -S "$SOCK" && break; sleep 1; done
sudo test -S "$SOCK" || { sudo cat /tmp/podman-service.log; exit 1; }
echo "::endgroup::"

echo "::group::start all-in-one (rootful, cni, SQLite) with in-process rusternetes-dns"
# Bridge gateway of rusternetes-network: the in-process DNS binds here (pods reach it,
# and it avoids the host's 127.0.0.53:53 stub that a 0.0.0.0:53 bind collides with).
# Recreate the pod network WITHOUT podman's aardvark-dns (which binds gateway:53 and
# would block the in-process rusternetes-dns) and with a fixed subnet so the gateway is
# deterministically 10.89.0.1 (covered by the cert SANs). Pods get DNS from the cluster
# (rusternetes-dns via kube-dns), not aardvark, so disabling it is safe.
sudo podman network rm -f rusternetes-network >/dev/null 2>&1 || true
sudo podman network create --disable-dns --subnet 10.89.0.0/24 rusternetes-network >/dev/null 2>&1 || true
GW=$(sudo podman network inspect rusternetes-network | jq -r '.[0].subnets[0].gateway')
echo "bridge gateway: ${GW:-<none>}"
# Keep the bridge interface up (GW assigned to the host) for the whole run, so the
# in-process DNS bind to GW:53 succeeds.
sudo podman rm -f rkt-netkeeper >/dev/null 2>&1 || true
sudo podman run -d --name rkt-netkeeper --network rusternetes-network docker.io/library/busybox:1.36 sleep 3600 >/dev/null 2>&1 || true
# Regenerate certs as root (generate-certs.sh detects the rootful gateway; harmless here).
sudo rm -rf "$SRC/.rusternetes/certs" "$SRC/.rusternetes/volumes/coredns"
( cd "$SRC" && sudo bash scripts/generate-certs.sh )
sudo env DOCKER_HOST="unix://$SOCK" "$SRC/target/release/rusternetes" \
  --data-dir "$SRC/cluster.db" --storage-backend sqlite --bind-address 0.0.0.0:6443 --tls \
  --tls-cert-file "$SRC/.rusternetes/certs/api-server.crt" --tls-key-file "$SRC/.rusternetes/certs/api-server.key" \
  --node-name node-1 --volume-dir "$SRC/.rusternetes/volumes" --pod-network-mode cni \
  --dns-bind "${GW}:53" </dev/null &>"$RKT_LOG" &
ok=""
for i in $(seq 1 60); do curl -sfk https://localhost:6443/healthz >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || fail "apiserver not healthy"
echo "apiserver healthy"
# Generate a real kubeconfig (server + insecure-skip-tls-verify + token) and point
# KUBECONFIG at it, so the in-tree kubectl stops warning "Could not load kubeconfig".
KUBECONFIG_OUT="$KCFG" bash "$SRC/scripts/generate-kubeconfig.sh" >/dev/null || fail "generate-kubeconfig.sh"
export KUBECONFIG="$KCFG"
echo "kubeconfig: $KCFG"
echo "::endgroup::"

echo "::group::wire kube-dns Service -> in-process rusternetes-dns (no CoreDNS)"
( cd "$SRC" && sudo bash scripts/generate-default-serviceaccounts.sh ) || fail "generate-default-serviceaccounts.sh"
# Certs/SAs generated as root; make readable so the user-run kubectl can read the SA YAML.
sudo chmod -R a+rX "$SRC/.rusternetes"
kctl apply -f "$SRC/.rusternetes/default-serviceaccounts.yaml" || fail "apply serviceaccounts"
kctl apply -f "$SRC/bootstrap-cluster.yaml" || fail "apply bootstrap-cluster.yaml"
# Point kube-dns (ClusterIP 10.96.0.10) at the all-in-one's in-process rusternetes-dns
# (GW:53) via a manual EndpointSlice — mirrors bootstrap-cluster.sh USE_RUSTERNETES_DNS=1.
# No CoreDNS pod is applied; kube-proxy DNATs cluster DNS to GW:53.
kctl apply -f - <<EOF || fail "apply kube-dns EndpointSlice"
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: kube-dns-rusternetes
  namespace: kube-system
  labels:
    kubernetes.io/service-name: kube-dns
    endpointslice.kubernetes.io/managed-by: rusternetesdns-stack
addressType: IPv4
ports:
  - { name: dns, port: 53, protocol: UDP }
  - { name: dns-tcp, port: 53, protocol: TCP }
endpoints:
  - addresses: ["${GW}"]
    conditions: { ready: true, serving: true, terminating: false }
EOF
# This stack must NOT use CoreDNS — assert no CoreDNS pod exists.
kctl get pods -n kube-system 2>/dev/null | grep -qi coredns && fail "unexpected CoreDNS pod present"
echo "kube-dns wired to in-process rusternetes-dns at ${GW}:53"
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
[ "$dnsok" = 1 ] || fail "DNS test pod did not Succeed (rusternetes-dns resolution)"
echo "DNS resolved via rusternetes-dns"
echo "::endgroup::"

echo "::group::verify pods ran on youki"
cid=$(sudo podman ps --format '{{.ID}} {{.Names}}' | grep -iE 'web|nginx' | awk '{print $1}' | head -1)
[ -n "$cid" ] || fail "no web container in podman"
rt=$(sudo podman inspect "$cid" --format '{{.OCIRuntime}}'); echo "OCIRuntime=$rt"
echo "$rt" | grep -qi youki || fail "OCIRuntime not youki: $rt"
echo "::endgroup::"

echo "PASS: rusternetes-podman-youki-rusternetesdns smoke test"
