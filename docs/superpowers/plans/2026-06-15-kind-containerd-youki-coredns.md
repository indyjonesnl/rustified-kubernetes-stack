# kind-containerd-youki-coredns Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a kind-based single-node Kubernetes stack whose container runtime exec path is fully Rust (`containerd-shim-runc-v2-rs` Rust shim driving the Youki OCI runtime) as containerd's **default** runtime, prove it with a kubectl smoke test, and run the whole thing in GitHub Actions with a status badge.

**Architecture:** A custom kind node image bakes the `youki` and `containerd-shim-runc-v2-rs` binaries into `kindest/node`. A kind cluster config registers a containerd runtime handler `rust-youki` (`runtime_type = io.containerd.runc.v2-rs`, `BinaryName = youki`) and sets it as `default_runtime_name`, so every pod — including system pods (CoreDNS, kube-proxy, kindnet, local-path) — runs on the Rust shim + Youki. A bash/kubectl smoke test exercises Deployment, Service+kube-proxy, CoreDNS, ConfigMap/Secret, Job, PVC, exec, and probes, then verifies Youki actually executed the containers. A Makefile wires build→up→smoke→down; a GitHub Actions workflow runs the same locally-reproducible steps.

**Tech Stack:** kind v0.31.x, Kubernetes v1.35, containerd (as shipped in `kindest/node`), Youki (built from source), containerd-rust-extensions `containerd-shim-runc-v2-rs` (built from source), Docker/buildx, bash + kubectl, GitHub Actions.

**Key risk (front-loaded in Task 3):** making `rust-youki` the *default* runtime means a Youki failure on any **system** pod blocks cluster boot. If boot fails, the documented contingency is to drop `default_runtime_name` and instead opt smoke workloads in via a `rust-youki` RuntimeClass. Task 3 validates boot before any further work depends on it.

**containerd config caveat:** `kindest/node:v1.35` may ship containerd 2.x, where the CRI config plugin id is `io.containerd.cri.v1.runtime` rather than the 1.x `io.containerd.grpc.v1.cri`. Task 3 inspects the node's *actual* config first and mirrors its structure — do not assume the plugin id.

---

## File Structure

```
stacks/kind-containerd-youki-coredns/
  Dockerfile.node          # builder stage(s) compile youki + rust shim → final FROM kindest/node
  kind-config.yaml         # containerdConfigPatches: register rust-youki handler + default_runtime_name
  runtimeclass.yaml        # rust-youki RuntimeClass (used only in the opt-in contingency)
  Makefile                 # build / up / smoke / down / clean targets
  smoke/
    manifests.yaml         # ns + ConfigMap + Secret + Deployment + Service + PVC + Job + DNS-test Job
    smoke-test.sh          # apply → wait → assert → DNS → exec → verify-runtime → cleanup
.github/workflows/kind-containerd-youki-coredns.yml
README.md                  # CI badge + quickstart (created/updated)
```

Each file has one responsibility: the Dockerfile produces binaries-in-a-node-image, the kind config wires containerd, the manifests declare the workload surface, the script asserts behavior, the Makefile is the single entrypoint both humans and CI call.

---

## Task 1: Repo scaffolding

**Files:**
- Create: `stacks/kind-containerd-youki-coredns/.gitkeep`
- Create: `stacks/kind-containerd-youki-coredns/smoke/.gitkeep`

- [ ] **Step 1: Create the directory skeleton**

```bash
mkdir -p stacks/kind-containerd-youki-coredns/smoke
touch stacks/kind-containerd-youki-coredns/.gitkeep
touch stacks/kind-containerd-youki-coredns/smoke/.gitkeep
```

- [ ] **Step 2: Verify structure**

Run: `find stacks -type d`
Expected: shows `stacks/kind-containerd-youki-coredns` and `stacks/kind-containerd-youki-coredns/smoke`.

- [ ] **Step 3: Commit**

```bash
git add stacks/kind-containerd-youki-coredns
git commit -m "chore: scaffold kind-containerd-youki-coredns stack dir"
```

---

## Task 2: Custom kind node image (youki + Rust shim baked in)

**Files:**
- Create: `stacks/kind-containerd-youki-coredns/Dockerfile.node`

This builds both Rust binaries from source in builder stages, then copies them into a `kindest/node` image so the binaries are present *before* containerd starts.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1

# ---- Build Youki (Rust OCI runtime) ----
FROM rust:1-bookworm AS youki-build
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libseccomp-dev libsystemd-dev libelf-dev libclang-dev \
      build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/youki-dev/youki .
# youki's binary crate is `youki`; output lands in target/release/youki
RUN cargo build --release --bin youki
RUN /src/target/release/youki --version

# ---- Build the Rust runc v2 shim (containerd-rust-extensions) ----
FROM rust:1-bookworm AS shim-build
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config build-essential git ca-certificates protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/containerd/rust-extensions .
# The runc shim binary must be named `containerd-shim-runc-v2-rs` so containerd
# resolves runtime_type "io.containerd.runc.v2-rs" to it.
RUN cargo build --release --bin containerd-shim-runc-v2-rs
RUN ls -l /src/target/release/containerd-shim-runc-v2-rs

# ---- Final kind node image ----
FROM kindest/node:v1.35.0
COPY --from=youki-build /src/target/release/youki /usr/local/bin/youki
COPY --from=shim-build  /src/target/release/containerd-shim-runc-v2-rs /usr/local/bin/containerd-shim-runc-v2-rs
RUN chmod +x /usr/local/bin/youki /usr/local/bin/containerd-shim-runc-v2-rs
```

- [ ] **Step 2: Build the image (this is the test — binaries must compile and the image must assemble)**

Run:
```bash
docker build -f stacks/kind-containerd-youki-coredns/Dockerfile.node \
  -t kind-node-youki:dev stacks/kind-containerd-youki-coredns
```
Expected: build succeeds; the `--version` and `ls` RUN lines print a youki version and the shim binary path. If `cargo build --bin <name>` fails because the crate/bin name differs, run `cargo metadata --no-deps --format-version 1 | grep -o '"name":"[^"]*"'` inside the builder to find the real bin target and adjust the `--bin` flag. If youki build fails on a missing system lib, add it to the `apt-get install` line.

- [ ] **Step 3: Verify the binaries are inside the final image**

Run:
```bash
docker run --rm --entrypoint /usr/local/bin/youki kind-node-youki:dev --version
docker run --rm --entrypoint ls kind-node-youki:dev -l /usr/local/bin/containerd-shim-runc-v2-rs
```
Expected: youki prints its version; the shim binary is listed and executable.

- [ ] **Step 4: Commit**

```bash
git add stacks/kind-containerd-youki-coredns/Dockerfile.node
git commit -m "feat: custom kind node image with youki + rust shim"
```

---

## Task 3: kind config + cluster boot with Youki as default runtime (RISK SPIKE)

**Files:**
- Create: `stacks/kind-containerd-youki-coredns/kind-config.yaml`
- Create: `stacks/kind-containerd-youki-coredns/runtimeclass.yaml`

Validate the riskiest assumption before building anything on top of it: does the cluster boot with `rust-youki` as the **default** runtime for all pods?

- [ ] **Step 1: Write the kind config (containerd 2.x plugin id form)**

```yaml
# stacks/kind-containerd-youki-coredns/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: youki
nodes:
  - role: control-plane
containerdConfigPatches:
  - |-
    [plugins.'io.containerd.cri.v1.runtime'.containerd]
      default_runtime_name = "rust-youki"
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'rust-youki']
      runtime_type = "io.containerd.runc.v2-rs"
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'rust-youki'.options]
      BinaryName = "/usr/local/bin/youki"
      SystemdCgroup = true
```

- [ ] **Step 2: Write the RuntimeClass (used only by the opt-in contingency)**

```yaml
# stacks/kind-containerd-youki-coredns/runtimeclass.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: rust-youki
handler: rust-youki
```

- [ ] **Step 3: Confirm the containerd config plugin id BEFORE relying on the patch**

Boot a throwaway *default* node from our image to read its real containerd config:
```bash
kind create cluster --name probe --image kind-node-youki:dev --wait 60s
docker exec youki-control-plane sh -c 'containerd --version; grep -n "cri" /etc/containerd/config.toml | head' \
  2>/dev/null || docker exec probe-control-plane sh -c 'containerd --version; grep -n "cri" /etc/containerd/config.toml | head'
```
Expected: prints containerd version and the CRI plugin section header. **If the config uses `io.containerd.grpc.v1.cri` instead of `io.containerd.cri.v1.runtime`, edit `kind-config.yaml` to match that plugin id** (replace the three `io.containerd.cri.v1.runtime` occurrences). Then delete the probe: `kind delete cluster --name probe`.

- [ ] **Step 4: Create the real cluster with the patched config**

Run:
```bash
kind delete cluster --name youki 2>/dev/null || true
kind create cluster --image kind-node-youki:dev \
  --config stacks/kind-containerd-youki-coredns/kind-config.yaml --wait 120s
```
Expected: cluster creation reports control-plane Ready within the wait window.

- [ ] **Step 5: Verify boot + that system pods ran on the Rust shim**

Run:
```bash
kubectl get nodes
kubectl -n kube-system wait --for=condition=Ready pod --all --timeout=120s
docker exec youki-control-plane ps aux | grep -c '[c]ontainerd-shim-runc-v2-rs'
```
Expected: node is `Ready`; kube-system pods (CoreDNS, kube-proxy, kindnet, etcd, apiserver, local-path) become Ready; the grep count is `> 0`, proving the Rust shim executed real containers.

**Contingency if Step 4/5 fails (cluster will not boot with Youki as default):**
Youki cannot yet run some system pod. Switch to opt-in mode: remove the `default_runtime_name` line from `kind-config.yaml` (keep the handler stanza), recreate the cluster, and in Task 4 add `runtimeClassName: rust-youki` to the smoke workloads (apply `runtimeclass.yaml` first). Record the regression in the stack doc's risk section. Do not proceed to Task 4 until the cluster boots in one of the two modes.

- [ ] **Step 6: Tear down and commit**

```bash
kind delete cluster --name youki
git add stacks/kind-containerd-youki-coredns/kind-config.yaml stacks/kind-containerd-youki-coredns/runtimeclass.yaml
git commit -m "feat: kind config running youki+rust-shim as default runtime"
```

---

## Task 4: Smoke test manifests

**Files:**
- Create: `stacks/kind-containerd-youki-coredns/smoke/manifests.yaml`

A single namespaced manifest bundle exercising many subsystems. All resources live in namespace `smoke` for clean teardown.

- [ ] **Step 1: Write the manifests**

```yaml
# stacks/kind-containerd-youki-coredns/smoke/manifests.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: smoke
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: smoke
data:
  message: "hello-from-configmap"
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: smoke
type: Opaque
stringData:
  token: "s3cr3t-token"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: smoke
spec:
  replicas: 2
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          env:
            - name: APP_TOKEN
              valueFrom:
                secretKeyRef: { name: app-secret, key: token }
          volumeMounts:
            - name: cfg
              mountPath: /etc/appcfg
          readinessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 2
            periodSeconds: 3
          livenessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: cfg
          configMap: { name: app-config }
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: smoke
spec:
  selector: { app: web }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: smoke
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources:
    requests:
      storage: 64Mi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: pvc-writer
  namespace: smoke
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: writer
          image: busybox:1.36
          command: ["sh", "-c", "echo persisted > /data/marker && cat /data/marker"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: data }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: dns-test
  namespace: smoke
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: dns
          image: busybox:1.36
          command: ["sh", "-c", "nslookup web.smoke.svc.cluster.local"]
```

- [ ] **Step 2: Lint the manifests (offline validation, no cluster needed)**

Run:
```bash
kubectl apply --dry-run=client -f stacks/kind-containerd-youki-coredns/smoke/manifests.yaml
```
Expected: every object prints `... (dry run)` with no schema errors.

- [ ] **Step 3: Commit**

```bash
git add stacks/kind-containerd-youki-coredns/smoke/manifests.yaml
git commit -m "feat: smoke-test manifests for kind-containerd-youki-coredns"
```

---

## Task 5: Smoke test script

**Files:**
- Create: `stacks/kind-containerd-youki-coredns/smoke/smoke-test.sh`

Drives apply → wait → assert across all subsystems, verifies Youki actually ran the containers, then cleans up. Idempotent and CI-safe (`set -euo pipefail`).

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x stacks/kind-containerd-youki-coredns/smoke/smoke-test.sh
```

- [ ] **Step 3: Run it end-to-end against a live cluster (the real test)**

Run:
```bash
kind create cluster --image kind-node-youki:dev \
  --config stacks/kind-containerd-youki-coredns/kind-config.yaml --wait 120s
bash stacks/kind-containerd-youki-coredns/smoke/smoke-test.sh
```
Expected: final line `PASS: kind-containerd-youki-coredns smoke test`; the shim-process count line shows `> 0`. If a `kubectl wait` times out, inspect with `kubectl -n smoke get pods,events` and fix the offending manifest or probe before continuing. Leave the cluster up for Task 6, or `kind delete cluster --name youki` to reclaim resources.

- [ ] **Step 4: Commit**

```bash
git add stacks/kind-containerd-youki-coredns/smoke/smoke-test.sh
git commit -m "feat: smoke-test driver script with youki runtime verification"
```

---

## Task 6: Makefile (single entrypoint for humans + CI)

**Files:**
- Create: `stacks/kind-containerd-youki-coredns/Makefile`

- [ ] **Step 1: Write the Makefile**

```makefile
# stacks/kind-containerd-youki-coredns/Makefile
IMAGE   ?= kind-node-youki:dev
CLUSTER ?= youki
DIR     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: image up smoke down clean all

image:
	docker build -f $(DIR)Dockerfile.node -t $(IMAGE) $(DIR)

up:
	kind delete cluster --name $(CLUSTER) 2>/dev/null || true
	kind create cluster --image $(IMAGE) --config $(DIR)kind-config.yaml --wait 120s

smoke:
	bash $(DIR)smoke/smoke-test.sh

down:
	kind delete cluster --name $(CLUSTER) 2>/dev/null || true

clean: down
	docker rmi $(IMAGE) 2>/dev/null || true

all: image up smoke down
```

- [ ] **Step 2: Test the full lifecycle through make**

Run:
```bash
make -C stacks/kind-containerd-youki-coredns all
```
Expected: builds the image, boots the cluster, prints the smoke `PASS` line, tears down. Exit code 0.

- [ ] **Step 3: Commit**

```bash
git add stacks/kind-containerd-youki-coredns/Makefile
git commit -m "feat: Makefile entrypoint for kind-containerd-youki-coredns stack"
```

---

## Task 7: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/kind-containerd-youki-coredns.yml`

Runs the exact same Makefile flow on `ubuntu-latest`. `workflow_dispatch` allows manual runs; path filters avoid running on unrelated changes.

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/kind-containerd-youki-coredns.yml
name: kind-containerd-youki-coredns

on:
  push:
    branches: [main]
    paths:
      - 'stacks/kind-containerd-youki-coredns/**'
      - '.github/workflows/kind-containerd-youki-coredns.yml'
  pull_request:
    paths:
      - 'stacks/kind-containerd-youki-coredns/**'
      - '.github/workflows/kind-containerd-youki-coredns.yml'
  workflow_dispatch:

jobs:
  smoke:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Install kind
        run: |
          curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
          chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
          kind version

      - name: Install kubectl
        uses: azure/setup-kubectl@v4

      - name: Build node image, run cluster + smoke test
        run: make -C stacks/kind-containerd-youki-coredns all
```

- [ ] **Step 2: Validate the workflow YAML locally**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/kind-containerd-youki-coredns.yml')); print('yaml ok')"
```
Expected: prints `yaml ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/kind-containerd-youki-coredns.yml
git commit -m "ci: kind-containerd-youki-coredns smoke workflow"
```

- [ ] **Step 4: Verify in CI after push (deferred until a remote exists)**

Once the repo has a GitHub remote and this is pushed, trigger the workflow (`gh workflow run kind-containerd-youki-coredns.yml`) or push to a branch, and confirm it goes green. If the runner cannot build/run nested OCI runtimes (cgroup v2 / privilege limits noted in the design risks), capture the failure and fall back to the opt-in RuntimeClass mode from Task 3's contingency.

---

## Task 8: README with badge + quickstart

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

````markdown
# Rustified Kubernetes Stack

Building a Kubernetes stack that uses Rust components wherever a viable one exists.
Design & roadmap: [`docs/rustified-kubernetes-stack.md`](docs/rustified-kubernetes-stack.md).

## Stack CI status

| Stack | Status |
|-------|--------|
| `kind-containerd-youki-coredns` | ![kind-containerd-youki-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kind-containerd-youki-coredns.yml/badge.svg) |

> All-green = every documented stack still builds and passes its smoke test. A red
> badge pinpoints which component combination regressed.

## kind-containerd-youki-coredns

Single-node kind cluster whose container runtime exec path is fully Rust:
`containerd-shim-runc-v2-rs` (Rust shim) driving the **Youki** OCI runtime, set as
containerd's default runtime so every pod — including system pods — runs on it.

Requirements: Docker, `kind`, `kubectl`, `make`.

```bash
make -C stacks/kind-containerd-youki-coredns all     # build image, up, smoke, down
# or step by step:
make -C stacks/kind-containerd-youki-coredns image
make -C stacks/kind-containerd-youki-coredns up
make -C stacks/kind-containerd-youki-coredns smoke
make -C stacks/kind-containerd-youki-coredns down
```
````

- [ ] **Step 2: Confirm the badge owner/repo slug**

The badge URL assumes the GitHub slug `indyjonesnl/rustified-kubernetes-stack`. Run `git remote -v`; if a remote exists with a different owner/repo, update the badge URL to match. If no remote exists yet, leave the assumed slug and fix it when the remote is added.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with stack CI badge + quickstart"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** Tasks cover every component of the `kind-containerd-youki-coredns` stack from the design doc (kind, containerd, Rust shim, Youki, CoreDNS), the multi-subsystem smoke test, local reproducibility (Makefile), CI (workflow), and the badge.
- **Default-runtime risk:** Task 3 is the gate — do not build Tasks 4-8 on an unbooted cluster. The opt-in RuntimeClass contingency is wired through Tasks 3 → 4 → 7.
- **Don't assume the containerd plugin id** — Task 3 Step 3 makes you read it from the live node before trusting the patch.
- **Binary/target names** (`youki`, `containerd-shim-runc-v2-rs`) are used consistently across Dockerfile, kind config, and smoke verification; if a cargo `--bin` target name differs at build time, fix it in Task 2 Step 2 and keep the installed binary names unchanged.
```
