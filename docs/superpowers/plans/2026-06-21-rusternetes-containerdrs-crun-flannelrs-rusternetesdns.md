# rusternetes-containerdrs-crun-flannelrs-rusternetesdns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the most-Rust K8s stack in this repo — Rusternetes (CRI kubelet) → containerd-rs → crun, with flannel-rs CNI and rusternetes-dns — and prove it with a smoke test plus at least one passing `[NodeConformance]` ginkgo test.

**Architecture:** Fork the proven Rusternetes `build/compose-cri-runtime` compose harness (CRI kubelet + flannel-rs + rusternetes-dns + the upstream `e2e.test` runner, which already passes sig-node on stock-containerd+Youki) and swap exactly one service: replace the *stock containerd + Youki* runtime image with a **containerd-rs + crun** image that binds the same CRI socket path. Everything else is reused unchanged.

**Tech Stack:** Rust (containerd-rs, Rusternetes, flannel-rs, rusternetes-dns), crun (C OCI runtime), Docker Compose, upstream Kubernetes `e2e.test` / ginkgo, bash + Make.

## Global Constraints

- **This is infrastructure glue, not a unit-tested library.** Each task's "test" is a concrete runtime verification command with expected output, run before the task is considered done. There is no red-green unit cycle; the verification gate is the test.
- **Stack dir:** `stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/` (in this repo).
- **rusternetes source:** sibling `../rusternetes`, branch `build/compose-cri-runtime`, pinned to an exact CRI-era SHA recorded in `setup.sh` (other stacks pin e.g. `923fec0d`). Resolution: env `RUSTERNETES_SRC` > sibling checkout > pinned clone.
- **containerd-rs source:** sibling `../containerd-rs`. Build: `make release` → `target/release/containerd-rs`. Resolution: env `CONTAINERD_RS_SRC` > sibling > pinned clone.
- **crun pin (verbatim):** `CRUN_VERSION=1.28`, `CRUN_SHA256=2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42`, URL `https://github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-amd64`.
- **crun selection:** containerd-rs hardcodes the OCI binary name `runc`. Install crun **as** the `runc` binary on the daemon PATH: `install -m0755 crun /usr/local/sbin/runc`. (No containerd-rs code change; the `cri.runtime_binary` config-field fix is a separate follow-up, out of scope here.)
- **Drop-in socket:** containerd-rs `cri_socket = "/run/containerd/containerd.sock"` — the path the kubelet/`Dockerfile.node` already expect, so no endpoint change anywhere else.
- **cgroup driver:** cgroupfs everywhere (containerd-rs `systemd_cgroup=false`, kubelet `--cgroup-driver=cgroupfs`).
- **K8s conformance version:** `K8S_VERSION=v1.35.0` (matches the branch's `run-node-conformance.sh`).
- **Git:** commit with the public **Indy Jones** identity (a pre-push hook blocks the private one). Commit locally per task; push only when the user asks.

---

### Task 1: Scaffold the stack dir + build containerd-rs

**Files:**
- Create: `stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/setup.sh`
- Create: `stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/.gitignore` (ignore `.rusternetes-src-path`, clones)

**Interfaces:**
- Produces: a built `containerd-rs` release binary at `$CONTAINERD_RS_SRC/target/release/containerd-rs`; a built Rusternetes checkout at `$RUSTERNETES_SRC` on the CRI branch; a `.rusternetes-src-path` file holding `$RUSTERNETES_SRC` for downstream scripts.

- [ ] **Step 1: Discover the exact CRI-era rusternetes SHA to pin**

Run (does not modify the tree):
```bash
cd ../rusternetes && git log -1 --format=%H fork/build/compose-cri-runtime
```
Record the printed SHA; use it as `RUSTERNETES_REF` default in `setup.sh`.

- [ ] **Step 2: Write `setup.sh`** (resolve/clone both repos, build containerd-rs)

```bash
#!/usr/bin/env bash
# Resolve rusternetes (CRI branch) + containerd-rs sources, build containerd-rs --release.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUSTERNETES_REF="${RUSTERNETES_REF:-<SHA-from-step-1>}"
RUSTERNETES_SRC="${RUSTERNETES_SRC:-}"
if [ -z "$RUSTERNETES_SRC" ]; then
  if [ -d "$REPO_ROOT/../rusternetes/.git" ]; then RUSTERNETES_SRC="$(cd "$REPO_ROOT/../rusternetes" && pwd)";
  else RUSTERNETES_SRC="$REPO_ROOT/.rusternetes-src";
       git clone --recurse-submodules https://github.com/indyjonesnl/rusternetes.git "$RUSTERNETES_SRC";
       ( cd "$RUSTERNETES_SRC" && git checkout "$RUSTERNETES_REF" && git submodule update --init --recursive ); fi
fi

CONTAINERD_RS_SRC="${CONTAINERD_RS_SRC:-}"
if [ -z "$CONTAINERD_RS_SRC" ]; then
  if [ -d "$REPO_ROOT/../containerd-rs/.git" ]; then CONTAINERD_RS_SRC="$(cd "$REPO_ROOT/../containerd-rs" && pwd)";
  else CONTAINERD_RS_SRC="$REPO_ROOT/.containerd-rs-src";
       git clone https://github.com/indyjonesnl/containerd-rs.git "$CONTAINERD_RS_SRC"; fi
fi

echo "==> build containerd-rs --release ($CONTAINERD_RS_SRC)"
make -C "$CONTAINERD_RS_SRC" release

echo "$RUSTERNETES_SRC"   > "$SCRIPT_DIR/.rusternetes-src-path"
echo "$CONTAINERD_RS_SRC" > "$SCRIPT_DIR/.containerd-rs-src-path"
echo "==> sources ready: rusternetes=$RUSTERNETES_SRC containerd-rs=$CONTAINERD_RS_SRC"
```

- [ ] **Step 3: Run it and verify both sources build**

Run:
```bash
bash stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/setup.sh
"$(cat stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/.containerd-rs-src-path)"/target/release/containerd-rs --help
```
Expected: setup completes; `containerd-rs --help` prints usage (confirms the release binary exists and runs).

- [ ] **Step 4: Commit**

```bash
git add stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/setup.sh \
        stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/.gitignore
git commit -m "feat(stack): scaffold rusternetes-containerdrs-crun-flannelrs-rusternetesdns + build containerd-rs"
```

---

### Task 2: containerd-rs + crun runtime image, proven standalone

**Files:**
- Create: `.../Dockerfile.containerd-rs`
- Create: `.../config/containerd-rs.config.toml`
- Create: `.../config/entrypoint.sh`

**Interfaces:**
- Consumes: `target/release/containerd-rs` (Task 1).
- Produces: a Docker image (tag `rusternetes-containerd-rs:dev`) that, run privileged, binds the CRI socket at `/run/containerd/containerd.sock` and runs containers via crun.

- [ ] **Step 1: Write `config/containerd-rs.config.toml`** (drop-in socket + cgroupfs)

```toml
root = "/var/lib/containerd-rs"
state = "/run/containerd-rs"
cri_socket = "/run/containerd/containerd.sock"
stream_server_address = "127.0.0.1:10010"

[cri]
sandbox_image = "registry.k8s.io/pause:3.10"
systemd_cgroup = false
snapshotter = "overlayfs"
cni_conf_dir = "/etc/cni/net.d"
cni_bin_dir  = "/opt/cni/bin"
```

- [ ] **Step 2: Write `config/entrypoint.sh`**

```bash
#!/usr/bin/env bash
set -eu
mkdir -p /run/containerd /var/lib/containerd-rs /run/containerd-rs /etc/cni/net.d /opt/cni/bin
exec containerd-rs --config /etc/containerd-rs/config.toml
```

- [ ] **Step 3: Write `Dockerfile.containerd-rs`** (crun installed AS `runc`)

```dockerfile
# containerd-rs (Rust CRI runtime) driving crun as the OCI runtime. Binds the CRI
# socket at /run/containerd/containerd.sock so it is a drop-in for the stock-containerd
# node image in the rusternetes compose harness.
FROM debian:sid-slim
ARG CRUN_VERSION=1.28
ARG CRUN_SHA256=2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl iptables \
    && rm -rf /var/lib/apt/lists/*
# crun installed AS `runc` — containerd-rs hardcodes the binary name "runc".
RUN curl -fsSL -o /usr/local/sbin/runc \
      "https://github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-amd64" \
    && echo "${CRUN_SHA256}  /usr/local/sbin/runc" | sha256sum -c - \
    && chmod +x /usr/local/sbin/runc \
    && /usr/local/sbin/runc --version
COPY target/release/containerd-rs /usr/local/bin/containerd-rs
COPY config/containerd-rs.config.toml /etc/containerd-rs/config.toml
COPY config/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
VOLUME ["/run/containerd"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Note the build context: the `COPY target/release/containerd-rs` line requires building with the containerd-rs checkout as context. The stack will build it as: `docker build -f .../Dockerfile.containerd-rs -t rusternetes-containerd-rs:dev "$CONTAINERD_RS_SRC"` after copying `config/` into the context, OR (simpler) copy the binary into the stack dir first. Use this concrete approach:

```bash
CRS="$(cat .../.containerd-rs-src-path)"
cp "$CRS/target/release/containerd-rs" .../target/release/containerd-rs   # mkdir -p target/release first
docker build -f .../Dockerfile.containerd-rs -t rusternetes-containerd-rs:dev .../
```
(Adjust `Dockerfile.containerd-rs` `COPY` paths to match the chosen context — `target/release/...` and `config/...` both under the stack dir.)

- [ ] **Step 4: Verify the image runs the CRI socket + crun (standalone, mirrors containerd-rs `ci/cni-node.sh`)**

Run:
```bash
docker run -d --rm --privileged --name crs-probe \
  -v /opt/cni/bin:/opt/cni/bin rusternetes-containerd-rs:dev
sleep 3
# CRI socket up + a sandbox runs on crun:
docker exec crs-probe sh -c '
  command -v crictl || (curl -fsSL https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.0/crictl-v1.31.0-linux-amd64.tar.gz | tar -xz -C /usr/local/bin)
  EP=unix:///run/containerd/containerd.sock
  crictl --runtime-endpoint $EP version
  /usr/local/sbin/runc --version'
docker rm -f crs-probe
```
Expected: `crictl version` prints `RuntimeName: containerd-rs` (or the daemon's reported name) over the socket; `runc --version` shows it is **crun** (`crun version 1.28`). This proves containerd-rs serves CRI and crun is the OCI binary.

- [ ] **Step 5: Commit**

```bash
git add stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/Dockerfile.containerd-rs \
        stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/config
git commit -m "feat(stack): containerd-rs+crun runtime image (drop-in CRI socket)"
```

---

### Task 3: Compose override — bring the CRI cluster up on containerd-rs

**Files:**
- Create: `.../compose.containerdrs.yml`

**Interfaces:**
- Consumes: `rusternetes-containerd-rs:dev` (Task 2); the rusternetes branch compose files.
- Produces: a running single-node CRI cluster whose runtime service is containerd-rs+crun; the node reaches `Ready`.

- [ ] **Step 1: Discover the runtime service name + how the node image is built in the harness**

Run:
```bash
RSRC="$(cat .../.rusternetes-src-path)"
git -C "$RSRC" show HEAD:compose.node-conformance.yml | grep -nA6 -iE 'containerd|Dockerfile.node|build:|image:'
```
Identify the service that builds from `Dockerfile.node`/`Dockerfile.containerd` (the runtime/node service) and the volume it shares (`/run/containerd`). This is the service to override.

- [ ] **Step 2: Write `compose.containerdrs.yml`** (override the runtime service to our image)

```yaml
# Override layered after compose.node-conformance.yml: replace the stock-containerd+Youki
# runtime with our containerd-rs+crun image. Same /run/containerd socket volume, so the
# CRI kubelet is unchanged.
services:
  <runtime-service-name>:        # from Step 1
    image: rusternetes-containerd-rs:dev
    build: !reset null           # do not rebuild the upstream Dockerfile.containerd
    # keep the upstream volumes/privileged/network from the base file
```
If `!reset` is unsupported by the installed compose version, instead point `build` at our Dockerfile:
```yaml
    build:
      context: ../../../<path-to-stack-dir>
      dockerfile: Dockerfile.containerd-rs
```

- [ ] **Step 3: Bring the cluster up via the branch runner with our override**

Run:
```bash
RSRC="$(cat .../.rusternetes-src-path)"
ABS="$(cd .../ && pwd)/compose.containerdrs.yml"
( cd "$RSRC" && EXTRA_COMPOSE_FILES="$ABS" RUSTERNETES_IMAGE_TAG= \
    bash scripts/run-node-conformance.sh --up-only 2>/dev/null \
    || EXTRA_COMPOSE_FILES="$ABS" docker compose -f compose.node-conformance.yml -f "$ABS" up -d --build )
```
(`run-node-conformance.sh` may not have `--up-only`; the `||` falls back to a direct compose up. Confirm the exact up path from the script read in Task 1 Step-equivalent.)

- [ ] **Step 4: Verify the node is Ready and talking to containerd-rs**

Run:
```bash
RSRC="$(cat .../.rusternetes-src-path)"; export KUBECONFIG="$HOME/.kube/rusternetes-config"
"$RSRC/target/release/kubectl" --insecure-skip-tls-verify get nodes -o wide
docker logs <runtime-service-container> 2>&1 | grep -iE 'serving|cri|listening' | head
```
Expected: node `node-1` `Ready`; runtime container log shows containerd-rs serving the CRI socket. If `kubectl` path/kubeconfig differ, derive them from `run-node-conformance.sh` (it writes `${HOME}/.kube/rusternetes-config`).

- [ ] **Step 5: Commit**

```bash
git add stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/compose.containerdrs.yml
git commit -m "feat(stack): compose override running the CRI cluster on containerd-rs+crun"
```

---

### Task 4: Verify flannel-rs pod networking under containerd-rs

**Files:** none new (flannel-rs DaemonSet is already in the harness).

**Interfaces:**
- Consumes: the running cluster (Task 3).
- Produces: confirmed pod-to-pod connectivity on flannel-rs over containerd-rs sandboxes.

- [ ] **Step 1: Confirm flannel-rs is the CNI and its DaemonSet is Ready**

Run:
```bash
export KUBECONFIG="$HOME/.kube/rusternetes-config"; K(){ "$RSRC/target/release/kubectl" --insecure-skip-tls-verify "$@"; }
K get ds -A | grep -i flannel
K get pods -A | grep -i flannel
docker exec <runtime-service-container> ls /etc/cni/net.d /opt/cni/bin
```
Expected: a flannel-rs DaemonSet with desired==ready; `/etc/cni/net.d` holds the flannel-rs conflist; `/opt/cni/bin` holds the flannel-rs plugins (`flannel`, `bridge`, `host-local`, `portmap`).

- [ ] **Step 2: Two pods on the pod network can reach each other**

Run:
```bash
K apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: net-a, namespace: default }
spec: { containers: [ { name: c, image: docker.io/library/busybox:1.36, command: ["sleep","3600"] } ] }
---
apiVersion: v1
kind: Pod
metadata: { name: net-b, namespace: default }
spec: { containers: [ { name: c, image: docker.io/library/busybox:1.36, command: ["sleep","3600"] } ] }
EOF
for i in $(seq 1 40); do K get pod net-a net-b -o wide | grep -c Running | grep -q 2 && break; sleep 3; done
IPB=$(K get pod net-b -o jsonpath='{.status.podIP}')
K exec net-a -- ping -c2 -W2 "$IPB"
```
Expected: both pods `Running` with flannel-subnet IPs (e.g. `10.244.x.x`); ping succeeds — flannel-rs works under containerd-rs.

- [ ] **Step 3: Commit** (a note/log only; no file change — fold into Task 6's smoke commit if no artifact). Skip if nothing to commit.

---

### Task 5: Verify rusternetes-dns (no CoreDNS)

**Files:** none new (rusternetes-dns + `bootstrap-dns.yaml` are in the harness).

**Interfaces:**
- Consumes: the running cluster.
- Produces: confirmed in-cluster DNS resolution via rusternetes-dns; CoreDNS absent.

- [ ] **Step 1: Confirm rusternetes-dns is serving and CoreDNS is absent**

Run:
```bash
K get svc -n kube-system kube-dns
K get pods -A | grep -i coredns && echo "UNEXPECTED COREDNS" && exit 1 || echo "no CoreDNS (good)"
docker ps --format '{{.Names}}' | grep -i dns
```
Expected: `kube-dns` Service exists (ClusterIP `10.96.0.10`); **no** CoreDNS pod; a rusternetes-dns container is running. (If DNS isn't auto-deployed by the harness, apply `kubectl apply -f "$RSRC/bootstrap-dns.yaml"`.)

- [ ] **Step 2: In-pod lookup of a Service resolves**

Run:
```bash
K apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata: { name: net-b-svc, namespace: default }
spec: { selector: { }, ports: [ { port: 80 } ] }
EOF
K run dnsq --image=docker.io/library/busybox:1.36 --restart=Never -- \
  sh -c 'nslookup kubernetes.default.svc.cluster.local && nslookup net-b-svc.default.svc.cluster.local'
for i in $(seq 1 30); do K get pod dnsq | grep -qiE 'Completed|Succeeded' && break; sleep 3; done
K logs dnsq
```
Expected: `nslookup` resolves `kubernetes.default` (and the test Service) via `10.96.0.10` — answered by rusternetes-dns.

- [ ] **Step 3:** No artifact; proceed.

---

### Task 6: End-to-end smoke script

**Files:**
- Create: `.../smoke/run.sh`

**Interfaces:**
- Consumes: the running cluster + the in-tree `kubectl`.
- Produces: a single script asserting Deployment+Service+DNS+pod-on-crun+containerd-rs-socket, exit 0 on success.

- [ ] **Step 1: Write `smoke/run.sh`** (adapt the shipped rusternetes-dns smoke; verify crun + containerd-rs instead of youki/podman)

```bash
#!/usr/bin/env bash
# Smoke: Deployment + Service + DNS via rusternetes-dns; verify the pod ran on crun under
# containerd-rs, and that no Docker/podman daemon nor CoreDNS is in the path.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RSRC="$(cat "$SCRIPT_DIR/../.rusternetes-src-path")"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/rusternetes-config}"
K(){ "$RSRC/target/release/kubectl" --insecure-skip-tls-verify "$@"; }
fail(){ echo "STACK FAIL: $*"; K get pods -A; exit 1; }

# 1. no CoreDNS
K get pods -A 2>/dev/null | grep -qi coredns && fail "unexpected CoreDNS pod"

# 2. Deployment + Service
K apply -f "$SCRIPT_DIR/manifests.yaml" || fail "apply manifests"
for i in $(seq 1 60); do K get pods -n smoke 2>/dev/null | grep -q 'web.*Running' && break; sleep 3; done
K get pods -n smoke | grep -q 'web.*Running' || fail "web not Running"

# 3. DNS via rusternetes-dns
K apply -f - <<'EOF'
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
ok=""; for i in $(seq 1 50); do s=$(K get pod dns-test -n smoke 2>/dev/null);
  echo "$s" | grep -qiE 'Succeeded|Completed' && { ok=1; break; }; echo "$s" | grep -qi Failed && break; sleep 3; done
[ "$ok" = 1 ] || fail "DNS resolution via rusternetes-dns failed"

# 4. pod ran on crun under containerd-rs (inspect the runtime container)
RC=$(docker ps --format '{{.Names}}' | grep -iE 'containerd|node|runtime' | head -1)
docker exec "$RC" sh -c 'crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps | grep -q web' \
  || fail "web container not visible via containerd-rs CRI"
docker exec "$RC" sh -c 'pgrep -a runc | grep -qi crun || /usr/local/sbin/runc --version | grep -qi crun' \
  || fail "OCI runtime is not crun"

echo "PASS: rusternetes-containerdrs-crun-flannelrs-rusternetesdns smoke"
```
(Refine `RC` selection and the crun-proof once the real runtime container name is known from Task 3.)

- [ ] **Step 2: Write `smoke/manifests.yaml`** (smoke namespace + Deployment + Service)

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: smoke }
---
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
---
apiVersion: v1
kind: Service
metadata: { name: web, namespace: smoke }
spec:
  selector: { app: web }
  ports: [ { port: 80, targetPort: 80 } ]
```

- [ ] **Step 3: Run smoke and verify PASS**

Run: `bash stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/smoke/run.sh`
Expected: ends with `PASS: rusternetes-containerdrs-crun-flannelrs-rusternetesdns smoke`.

- [ ] **Step 4: Commit**

```bash
git add stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/smoke
git commit -m "feat(stack): end-to-end smoke (Deployment+Service+rusternetes-dns+crun-on-containerd-rs)"
```

---

### Task 7: One passing `[NodeConformance]` ginkgo test

**Files:**
- Create: `.../conformance/run.sh`

**Interfaces:**
- Consumes: the running cluster; the branch's `scripts/run-node-conformance.sh` (fetches upstream `e2e.test`).
- Produces: a JUnit result showing ≥1 sig-node `[Conformance]` ginkgo test passed, 0 failed.

- [ ] **Step 1: Pick one cheap, reliable node-level conformance test**

Candidate focus (single test, no networking flakiness): the projected-configmap or env-var test, e.g.
`FOCUS='should print the output to logs \[NodeConformance\]'` (the busybox "output to logs" spec). Confirm the exact name exists in v1.35 by listing once:
```bash
# optional: --dry-run to list matching specs
```

- [ ] **Step 2: Write `conformance/run.sh`** (wrap the branch runner, narrowed FOCUS)

```bash
#!/usr/bin/env bash
# Run ONE sig-node [Conformance] ginkgo test against this stack via the branch's runner.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RSRC="$(cat "$SCRIPT_DIR/../.rusternetes-src-path")"
OVERRIDE="$(cd "$SCRIPT_DIR/.." && pwd)/compose.containerdrs.yml"
export EXTRA_COMPOSE_FILES="$OVERRIDE"
export K8S_VERSION="${K8S_VERSION:-v1.35.0}"
export FOCUS="${FOCUS:-should print the output to logs \\[NodeConformance\\]}"
export SKIP="${SKIP:-\\[Flaky\\]|\\[Serial\\]|\\[Slow\\]}"
( cd "$RSRC" && bash scripts/run-node-conformance.sh )
```

- [ ] **Step 3: Run it and verify ≥1 passed, 0 failed**

Run: `bash stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/conformance/run.sh`
Expected: ginkgo summary `1 Passed | 0 Failed` (or `N Passed | 0 Failed`) and a JUnit XML under `/tmp/node-conformance`. **This is the headline achievement.**

- [ ] **Step 4: Commit**

```bash
git add stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/conformance
git commit -m "feat(stack): one sig-node [Conformance] ginkgo test green on the all-Rust stack"
```

---

### Task 8: Makefile, README, CI workflow, roadmap

**Files:**
- Create: `.../Makefile`
- Modify: `README.md` (add a stack section + a CI status-badge row)
- Create: `.github/workflows/rusternetes-containerdrs-crun-flannelrs-rusternetesdns.yml`
- Modify: `docs/rustified-kubernetes-stack.md` (mark this stack; note it reaches the north star + the youki-variant follow-up)

**Interfaces:**
- Consumes: `setup.sh`, `smoke/run.sh`, `conformance/run.sh`.
- Produces: `make all` (setup → up → smoke) and `make conformance`; a CI workflow that runs setup+smoke on push.

- [ ] **Step 1: Write `Makefile`**

```makefile
DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: setup up smoke conformance clean all
setup:       ; bash $(DIR)setup.sh
up:          ; bash $(DIR)setup.sh && docker build -f $(DIR)Dockerfile.containerd-rs -t rusternetes-containerd-rs:dev $(DIR)
smoke:       ; bash $(DIR)smoke/run.sh
conformance: ; bash $(DIR)conformance/run.sh
clean:       ; -docker compose -f $$(cat $(DIR).rusternetes-src-path)/compose.node-conformance.yml -f $(DIR)compose.containerdrs.yml down -v
all: up smoke
```
(Reconcile `up` with the exact bring-up path settled in Task 3.)

- [ ] **Step 2: Add the README stack section + badge row**

Add under the status table a row:
```markdown
| `rusternetes-containerdrs-crun-flannelrs-rusternetesdns` | ![...](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-containerdrs-crun-flannelrs-rusternetesdns.yml/badge.svg) |
```
and a prose section describing the all-Rust path (Rusternetes CRI → containerd-rs → crun + flannel-rs + rusternetes-dns), the one-swap-from-the-CRI-harness framing, and the crun-not-Rust caveat.

- [ ] **Step 3: Write the CI workflow** (mirror an existing rusternetes stack workflow)

Run to use a proven template:
```bash
ls .github/workflows | grep rusternetes
```
Copy the closest (`rusternetes-podman-youki-rusternetesdns.yml`) and adapt: checkout this repo + the two sibling repos (or let `setup.sh` clone pinned), Docker available, run `make -C stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns all`. Keep conformance in a separate dispatch/nightly job (as the sig-network workflow is split).

- [ ] **Step 4: Update the roadmap doc** — add a `☑`/`◐` entry for this stack noting it reaches the all-Rust north star (crun aside) and lists the youki-variant + `runtime_binary` follow-ups.

- [ ] **Step 5: Verify make targets exist and the workflow is valid YAML**

Run:
```bash
make -C stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns -n all
python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/rusternetes-containerdrs-crun-flannelrs-rusternetesdns.yml"))' && echo "workflow YAML ok"
```
Expected: `make -n` prints the setup/build/smoke command chain; YAML loads without error.

- [ ] **Step 6: Commit**

```bash
git add stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/Makefile README.md \
        .github/workflows/rusternetes-containerdrs-crun-flannelrs-rusternetesdns.yml docs/rustified-kubernetes-stack.md
git commit -m "feat(stack): Makefile, README, CI workflow, roadmap for the all-Rust stack"
```

---

## Self-Review

**Spec coverage:**
- §1 components → Tasks 2 (containerd-rs+crun), 3 (CRI cluster), 4 (flannel-rs), 5 (rusternetes-dns). ✓
- §1 success criterion 1 (smoke) → Task 6. ✓
- §1 success criterion 2 (one ginkgo) → Task 7. ✓
- §4.1 drop-in socket → Task 2 Step 1 (config), Task 3. ✓
- §4.2 crun-as-runc → Task 2 Step 3 + Global Constraints. ✓
- §4.3 containerd-rs build → Task 1. ✓
- §4.4 reuse flannel-rs/dns/runner → Tasks 4, 5, 7. ✓
- §5 layout (Makefile/setup/Dockerfile/compose/smoke/conformance) → Tasks 1,2,3,6,7,8. ✓
- §6 roadmap (README/roadmap doc, youki follow-up) → Task 8. ✓

**Placeholder scan:** Remaining `<...>` items are explicit *discovery* steps with the exact command that yields the value (the pinned rusternetes SHA in Task 1 Step 1; the runtime service name in Task 3 Step 1; the runtime container name for the crun proof). These are unavoidable lookups against the rusternetes branch, each paired with the command to resolve it — not vague TODOs. Flagged honestly rather than guessed.

**Type/name consistency:** image tag `rusternetes-containerd-rs:dev`, socket `/run/containerd/containerd.sock`, kubeconfig `$HOME/.kube/rusternetes-config`, in-tree kubectl `$RSRC/target/release/kubectl`, and override file `compose.containerdrs.yml` are used consistently across Tasks 2–8.

**Known soft spots to resolve at execution (not guesses — confirmations):** the exact compose service name + bring-up entrypoint of `run-node-conformance.sh` (Task 3), and whether rusternetes-dns auto-deploys or needs `bootstrap-dns.yaml` (Task 5). Both have a verification command in-task.
