# rusternetes-podman-youki-coredns Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Formalize the proven spike into a real stack: the Rusternetes Rust control plane + kubelet running pods on **podman + Youki**, with **CoreDNS** for cluster DNS, proven by a kubectl smoke test (Deployment + Service + DNS + youki-runtime verification), CI-gated with a README badge.

**Architecture:** Host-level, **rootful**. Install pinned youki v0.6.0; configure rootful podman to use youki; create the `rusternetes-network`; build the Rusternetes all-in-one binary + its in-tree kubectl from `../rusternetes` (or clone the fork in CI). Start a rootful podman socket and the all-in-one (SQLite, `DOCKER_HOST`→podman, `--pod-network-mode netstack`, **no** `--client-ca-file`), bootstrap with `USE_RUSTERNETES_DNS=0` (CoreDNS). Smoke-test via the in-tree kubectl, then verify pods ran on youki (`OCIRuntime`).

**Tech stack:** Rusternetes (indyjonesnl fork, all-in-one + SQLite), Youki v0.6.0 (pinned), rootful Podman, in-tree kubectl, CoreDNS, bash, GitHub Actions ubuntu-latest.

**This is grounded in the PASSED spike** (CI run 27569874107). See memory `rusternetes-integration.md` for the verified recipe. Key gotchas baked in: in-tree kubectl (not upstream); no `--client-ca-file` (mTLS); rootful for `CAP_NET_ADMIN`; **must** `podman network create rusternetes-network`; in-tree kubectl `get pods` prints `Some(Running)` (match on `Running`).

**Verification reality:** rootful podman + a ~20-25min rusternetes build can't run on the dev host (no passwordless sudo / podman). Per-file checks are offline (`bash -n`, yaml parse); **CI is the authoritative gate**.

---

## File Structure
```
stacks/rusternetes-podman-youki-coredns/
  setup.sh           # pinned youki + rootful podman youki-runtime + rusternetes-network + build rusternetes & in-tree kubectl
  smoke/
    run.sh           # bring up all-in-one (rootful, netstack, CoreDNS bootstrap) + smoke (Deployment+Service+DNS) + verify youki; trap cleanup
  Makefile           # setup / smoke / clean / all
.github/workflows/rusternetes-podman-youki-coredns.yml
README.md            # badge row + section
```
`run.sh` does bring-up AND smoke in ONE process (mirrors the proven spike; avoids cross-make-target process-lifetime fragility).

---

## Task 1: setup.sh

**Files:** Create `stacks/rusternetes-podman-youki-coredns/setup.sh`

- [ ] **Step 1: Write it**
```bash
#!/usr/bin/env bash
# Install youki, configure rootful podman to use it, create the pod network,
# and build the Rusternetes all-in-one + in-tree kubectl. Rootful (uses sudo).
set -euo pipefail

YOUKI_VERSION="0.6.0"
YOUKI_SHA256="e920231ee35a157d48e267611a00c9d5f75b60b003818aa571dda04ca9196e59"
YOUKI_URL="https://github.com/youki-dev/youki/releases/download/v${YOUKI_VERSION}/youki-${YOUKI_VERSION}-x86_64-gnu.tar.gz"
# Rusternetes source: prefer a sibling checkout, else clone the fork.
SRC="${RUSTERNETES_SRC:-}"
if [ -z "$SRC" ]; then
  if [ -d "../rusternetes/.git" ]; then SRC="$(cd ../rusternetes && pwd)"
  else SRC="$PWD/.rusternetes-src"; fi
fi

echo "==> podman present?"; command -v podman >/dev/null || { sudo apt-get update && sudo apt-get install -y podman; }
podman --version

echo "==> install pinned youki ${YOUKI_VERSION}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/y.tgz" "$YOUKI_URL"
echo "${YOUKI_SHA256}  $tmp/y.tgz" | sha256sum -c -
tar xzf "$tmp/y.tgz" -C "$tmp" youki
sudo install -m 0755 "$tmp/youki" /usr/local/bin/youki
/usr/local/bin/youki --version

echo "==> rootful podman: default runtime youki + pod network"
sudo mkdir -p /etc/containers/containers.conf.d
sudo tee /etc/containers/containers.conf.d/youki.conf >/dev/null <<EOF
[engine]
runtime = "youki"
[engine.runtimes]
youki = ["/usr/local/bin/youki"]
EOF
sudo podman network create rusternetes-network 2>/dev/null || echo "(network exists)"

echo "==> build rusternetes all-in-one + in-tree kubectl (src: $SRC)"
if [ ! -d "$SRC/.git" ]; then
  git clone --recurse-submodules https://github.com/indyjonesnl/rusternetes.git "$SRC"
fi
( cd "$SRC" && git submodule update --init --recursive && cargo build --release --bin rusternetes --bin kubectl )
echo "$SRC" > "$PWD/.rusternetes-src-path"
echo "==> setup complete; rusternetes src at $SRC"
```

- [ ] **Step 2: `bash -n stacks/rusternetes-podman-youki-coredns/setup.sh && echo ok`**
- [ ] **Step 3: commit** `feat(rusternetes-podman-youki-coredns): setup (youki, rootful podman, network, build)` + Co-Authored-By trailer.

---

## Task 2: smoke/run.sh

**Files:** Create `stacks/rusternetes-podman-youki-coredns/smoke/run.sh`

- [ ] **Step 1: Write it**
```bash
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

cleanup() { sudo pkill -f 'target/release/rusternetes' 2>/dev/null || true; sudo podman pod rm -f $(sudo podman pod ls -q) 2>/dev/null || true; }
trap cleanup EXIT
diag() { echo "== rusternetes log =="; sudo tail -120 "$RKT_LOG" 2>/dev/null; echo "== pods =="; kctl get pods -A 2>&1|head -40; echo "== describe =="; kctl describe pod -n smoke -l app=web 2>&1|tail -30; }
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
for i in $(seq 1 60); do curl -sfk https://localhost:6443/healthz >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
[ "${ok:-}" = 1 ] || fail "apiserver not healthy"
echo "::endgroup::"

echo "::group::bootstrap CoreDNS (USE_RUSTERNETES_DNS=0)"
( cd "$SRC" && KUBECTL="$KBIN" USE_RUSTERNETES_DNS=0 bash scripts/bootstrap-cluster.sh ) || echo "(bootstrap nonzero; continuing)"
for i in $(seq 1 40); do kctl get pods -n kube-system 2>/dev/null | grep -qi 'coredns.*Running' && { dns=1; break; }; sleep 3; done
[ "${dns:-}" = 1 ] && echo "CoreDNS Running" || echo "(CoreDNS not confirmed Running; continuing)"
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
# wait web pod Running
for i in $(seq 1 60); do kctl get pods -n smoke 2>/dev/null | grep -q 'web.*Running' && { web=1; break; }; sleep 3; done
[ "${web:-}" = 1 ] || fail "web pod not Running"
echo "web Running"
# DNS test: busybox nslookup the Service FQDN (retry inside the pod)
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
for i in $(seq 1 50); do st=$(kctl get pods -n smoke 2>/dev/null | grep dns-test); echo "dns-test: $st"; echo "$st" | grep -qiE 'Succeeded|Completed' && { dnsok=1; break; }; echo "$st" | grep -qi 'Failed' && break; sleep 3; done
[ "${dnsok:-}" = 1 ] || fail "DNS test pod did not Succeed (CoreDNS resolution)"
echo "DNS resolved via CoreDNS"
echo "::endgroup::"

echo "::group::verify pods ran on youki"
cid=$(sudo podman ps --format '{{.ID}} {{.Names}}' | grep -iE 'web|nginx' | awk '{print $1}' | head -1)
[ -n "$cid" ] || fail "no web container in podman"
rt=$(sudo podman inspect "$cid" --format '{{.OCIRuntime}}'); echo "OCIRuntime=$rt"
echo "$rt" | grep -qi youki || fail "OCIRuntime not youki: $rt"
echo "::endgroup::"

echo "PASS: rusternetes-podman-youki-coredns smoke test"
```

- [ ] **Step 2: `bash -n .../smoke/run.sh && echo ok`; `chmod +x`.**
- [ ] **Step 3: commit** `feat(rusternetes-podman-youki-coredns): bring-up + smoke (Deployment/Service/DNS, youki verify)` + trailer.

---

## Task 3: Makefile
**Files:** Create `stacks/rusternetes-podman-youki-coredns/Makefile`
- [ ] **Step 1:** (TAB recipes)
```makefile
DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SUDO ?= sudo

.PHONY: setup smoke clean all
setup:
	bash $(DIR)setup.sh
smoke:
	bash $(DIR)smoke/run.sh
clean:
	$(SUDO) pkill -f 'target/release/rusternetes' 2>/dev/null || true
	$(SUDO) podman pod rm -fa 2>/dev/null || true
all: setup smoke
```
- [ ] **Step 2:** `make -C stacks/rusternetes-podman-youki-coredns --dry-run all`
- [ ] **Step 3: commit** `feat(rusternetes-podman-youki-coredns): Makefile` + trailer.

---

## Task 4: CI workflow
**Files:** Create `.github/workflows/rusternetes-podman-youki-coredns.yml`
- [ ] **Step 1:**
```yaml
name: rusternetes-podman-youki-coredns
on:
  push: { branches: [main], paths: ['stacks/rusternetes-podman-youki-coredns/**', '.github/workflows/rusternetes-podman-youki-coredns.yml'] }
  pull_request: { paths: ['stacks/rusternetes-podman-youki-coredns/**', '.github/workflows/rusternetes-podman-youki-coredns.yml'] }
  workflow_dispatch:
jobs:
  smoke:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - name: Ensure podman + build deps
        run: { podman --version || (sudo apt-get update && sudo apt-get install -y podman); sudo apt-get install -y protobuf-compiler jq; }
      - uses: dtolnay/rust-toolchain@stable
      - name: Clone rusternetes fork
        run: git clone --recurse-submodules https://github.com/indyjonesnl/rusternetes.git "$GITHUB_WORKSPACE/.rusternetes-src"
      - uses: Swatinem/rust-cache@v2
        with: { workspaces: .rusternetes-src }
      - name: Build + smoke
        env: { RUSTERNETES_SRC: '${{ github.workspace }}/.rusternetes-src' }
        run: make -C stacks/rusternetes-podman-youki-coredns all
```
(Note: the `run:` map-style step above is illustrative — write it as a real YAML `run: |` block with the commands on separate lines.)
- [ ] **Step 2:** `python3 -c "import yaml;yaml.safe_load(open('.github/workflows/rusternetes-podman-youki-coredns.yml'));print('ok')"`
- [ ] **Step 3: commit** `ci(rusternetes-podman-youki-coredns): smoke workflow` + trailer.

---

## Task 5: README badge + section
**Files:** Modify `README.md`
- [ ] Add table row `| \`rusternetes-podman-youki-coredns\` | ![...](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-podman-youki-coredns.yml/badge.svg) |` after the podman-youki row, plus a `## rusternetes-podman-youki-coredns` section (Rusternetes control plane + kubelet → podman → youki, CoreDNS DNS; `make -C stacks/rusternetes-podman-youki-coredns all`).
- [ ] **commit** `docs(rusternetes-podman-youki-coredns): badge + quickstart` + trailer.

---

## Task 6: retire the spike
- [ ] After the stack's CI is green on main, delete the throwaway spike: `git push origin --delete spike/rusternetes-podman-youki` and remove `spike/` + `.github/workflows/spike-rusternetes-podman-youki.yml` in a commit.

## Self-review notes
- CI is the gate; expect iteration on in-tree kubectl quirks (`get` column formats → match on `Running`/`Succeeded` text, not jsonpath) and CoreDNS readiness timing. The proven recipe (memory `rusternetes-integration.md`) covers the load-bearing gotchas.
- If Deployment/Service/DNS exceed in-tree kubectl's capabilities, fall back to the proven bare-pod-on-youki core + CoreDNS-Running assertion and record the limitation.
