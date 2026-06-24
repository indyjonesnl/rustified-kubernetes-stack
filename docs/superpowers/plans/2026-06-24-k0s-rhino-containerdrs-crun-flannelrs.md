# k0s-rhino-containerdrs-crun-flannelrs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A k0s single-node stack identical to PR #10 (`k0s-rhino-crun-flannelrs`) except the container engine is **containerd-rs v0.1.3** (Rust CRI) instead of k0s's bundled Go containerd — proven by smoke + gated per-SIG conformance.

**Architecture:** Fork the PR #10 stack. Bake the static-musl containerd-rs binary into a small node image `FROM k0sproject/k0s:v1.35.5-k0s.0`. The container entrypoint starts containerd-rs as a background daemon, then runs `k0s controller --enable-worker --no-taints --cri-socket remote:unix:///run/containerd-rs.sock` so k0s cedes the CRI to the external Rust daemon (no managed containerd). crun (OCI) and flannel-rs (CNI) wire the same way they do under containerd; rhino stays the datastore.

**Tech Stack:** k0s v1.35.5-k0s.0, containerd-rs v0.1.3 (`ghcr.io/indyjonesnl/containerd-rs:0.1.3`), crun 1.28, flannel-rs v0.1.3, rhino (Rust etcd-v3), Docker Compose, bash + ginkgo/e2e.test v1.35.5.

## Global Constraints

- **k8s version pinned** `k0sproject/k0s:v1.35.5-k0s.0`; `K8S_VERSION=v1.35.5` for e2e — copied verbatim from PR #10.
- **containerd-rs pinned** `ghcr.io/indyjonesnl/containerd-rs:0.1.3` (static musl binary; runs native on Alpine).
- **flannel-rs pinned** `ghcr.io/indyjonesnl/flannel-rs:0.1.3`, `imagePullPolicy: IfNotPresent` (containerd-rs pulls registry-only; no local-image load — never a `*:dev`/`Never`).
- **crun pinned** 1.28, sha256 `2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42`.
- **loopback CNI plugin** v1.6.2 installed to `/opt/cni/bin` (flannel-rs ships flannel/bridge/host-local/portmap only; containerd-rs invokes `loopback` for the pod `lo`).
- **Distinct identifiers** (shared Docker daemon): project `k0s-rhino-cdrsfl`, container names `k0s-rhino-cdrsfl-{backend,cluster}`, network `k0s-rhino-cdrsfl-net` subnet `172.33.7.0/24`, rhino IP `172.33.7.10`, host port `27443:6443`.
- **containerd-rs facts** (verified against the v0.1.3 checkout): default CRI socket `/run/containerd-rs.sock`; crun state root `/var/run/containerd-rs/crun`; CRI `Version` RPC reports `runtime_name="containerd-rs"`, `runtime_version="0.1.3"`; default `default_runtime_name="crun"`, `systemd_cgroup=false`, `snapshotter="overlayfs"`, `cni_conf_dir=/etc/cni/net.d`, `cni_bin_dir=/opt/cni/bin`, `sandbox_image="registry.k8s.io/pause:3.10"`.
- **No source changes to containerd-rs** — consume v0.1.3 as published; any gap is an upstream follow-up, not a fix here.
- **Honesty gate:** report real conformance counts; never widen SKIP or fake a green to hit a number.

---

### Task 1: Scaffold the stack from PR #10 (rename identifiers)

Pure copy + identifier rename. No engine change yet — this task's deliverable is a byte-faithful sibling that `docker compose config` validates and that still references PR #10's mechanics (those get swapped in Tasks 2–5).

**Files:**
- Create (copy): `stacks/k0s-rhino-containerdrs-crun-flannelrs/` ← copy of `stacks/k0s-rhino-crun-flannelrs/`
- Modify: `Makefile`, `docker-compose.yml`, `smoke/run.sh`, `conformance/run.sh`, `conformance/run-sigs.sh` (identifier strings only)

**Interfaces:**
- Produces: stack dir at `stacks/k0s-rhino-containerdrs-crun-flannelrs/` with project `k0s-rhino-cdrsfl`, node container `k0s-rhino-cdrsfl-cluster`, rhino IP `172.33.7.10`, apiserver host port `27443`. Tasks 2–7 edit files inside it.

- [ ] **Step 1: Copy the stack tree**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
cp -r stacks/k0s-rhino-crun-flannelrs stacks/k0s-rhino-containerdrs-crun-flannelrs
```

- [ ] **Step 2: Rename all identifiers (project, container names, network, IP, port)**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack/stacks/k0s-rhino-containerdrs-crun-flannelrs
# project + container/network prefixes
grep -rl 'k0s-rhino-crunfl' . | xargs sed -i 's/k0s-rhino-crunfl/k0s-rhino-cdrsfl/g'
# rhino static IP + subnet (172.32.7.x -> 172.33.7.x)
grep -rl '172\.32\.7' . | xargs sed -i 's/172\.32\.7/172.33.7/g'
# apiserver host port 26443 -> 27443 (compose maps + conformance APISERVER_PORT)
grep -rl '26443' . | xargs sed -i 's/26443/27443/g'
```

- [ ] **Step 3: Verify rename completeness**

Run:
```bash
grep -rn -e 'crunfl' -e '172\.32\.7' -e '26443' stacks/k0s-rhino-containerdrs-crun-flannelrs/ || echo "CLEAN"
```
Expected: `CLEAN` (no stale identifiers). The literal stack name `k0s-rhino-crun-flannelrs` may still appear in human-readable echo/comment strings — those get corrected in Task 8; only the *identifiers* above must be clean here.

- [ ] **Step 4: Validate compose still parses**

Run:
```bash
docker compose -p k0s-rhino-cdrsfl -f stacks/k0s-rhino-containerdrs-crun-flannelrs/docker-compose.yml config -q && echo OK
```
Expected: `OK` (no errors). It still describes the PR #10 mechanics; that's fine.

- [ ] **Step 5: Commit**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add stacks/k0s-rhino-containerdrs-crun-flannelrs
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "scaffold(k0s-rhino-containerdrs-crun-flannelrs): fork PR #10 stack + rename identifiers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Node image + entrypoint — run containerd-rs as the external CRI

Replace k0s's bundled containerd with containerd-rs. Bake the binary into a node image, and rewrite the entrypoint to launch the daemon and point k0s at its socket via `--cri-socket`. Remove PR #10's `containerd-crun.toml` (it configured k0s's containerd, which no longer runs).

**Files:**
- Create: `stacks/k0s-rhino-containerdrs-crun-flannelrs/Dockerfile.node`
- Delete: `stacks/k0s-rhino-containerdrs-crun-flannelrs/config/containerd-crun.toml`
- Modify: `stacks/k0s-rhino-containerdrs-crun-flannelrs/docker-compose.yml`

**Interfaces:**
- Consumes: `ghcr.io/indyjonesnl/containerd-rs:0.1.3` (external build stage), `/etc/containerd-rs.toml` (created in Task 3 — mount added here, file added there).
- Produces: a node where the kubelet's CRI endpoint is `unix:///run/containerd-rs.sock` served by containerd-rs; crun + loopback installed by the entrypoint.

- [ ] **Step 1: Create `Dockerfile.node`**

```dockerfile
# k0s v1.35 node image with the containerd-rs (Rust CRI) binary baked in. The
# binary is the static musl build published by containerd-rs's release workflow,
# so it runs natively on this Alpine-based k0s image. crun + the loopback CNI
# plugin are still installed at runtime by the compose entrypoint (same as PR #10).
FROM k0sproject/k0s:v1.35.5-k0s.0
# COPY --from=<image> pulls the published release image and lifts the static
# binary out of it. Pinned to v0.1.3.
COPY --from=ghcr.io/indyjonesnl/containerd-rs:0.1.3 /usr/local/bin/containerd-rs /usr/local/bin/containerd-rs
```

- [ ] **Step 2: Delete the obsolete k0s-containerd drop-in**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack/stacks/k0s-rhino-containerdrs-crun-flannelrs
git rm config/containerd-crun.toml
rmdir config 2>/dev/null || true
```

- [ ] **Step 3: Switch the k0s service to `build:` and mount swap in `docker-compose.yml`**

In `stacks/k0s-rhino-containerdrs-crun-flannelrs/docker-compose.yml`, the `k0s:` service currently has `image: k0sproject/k0s:v1.35.5-k0s.0`. Replace that single line with a build stanza:

```yaml
    build:
      context: .
      dockerfile: Dockerfile.node
    image: k0s-rhino-cdrsfl-node:v1.35.5
```

And in the same service's `volumes:`, replace the containerd-crun drop-in mount line:

```yaml
      - ./config/containerd-crun.toml:/etc/k0s/containerd.toml:ro
```

with the containerd-rs config mount (file authored in Task 3):

```yaml
      - ./config/containerd-rs.toml:/etc/containerd-rs.toml:ro
```

- [ ] **Step 4: Rewrite the entrypoint `command` block in `docker-compose.yml`**

Replace the existing `command:` block (the `crun` install + `exec k0s controller …` heredoc) with the version below. It keeps machine-id, crun, and loopback install verbatim from PR #10, then starts containerd-rs and waits for its socket before launching k0s with the external CRI socket.

```yaml
    command:
      - |
        [ -f /etc/machine-id ] || dd if=/dev/urandom status=none bs=16 count=1 | md5sum | cut -d' ' -f1 > /etc/machine-id
        if [ ! -x /usr/local/bin/crun ]; then
          wget -qO /usr/local/bin/crun "https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-amd64"
          echo "2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42  /usr/local/bin/crun" | sha256sum -c -
          chmod +x /usr/local/bin/crun
        fi
        /usr/local/bin/crun --version
        # containerd-rs invokes the standard 'loopback' plugin for the pod lo;
        # flannel-rs ships only flannel/bridge/host-local/portmap. Install loopback.
        if [ ! -x /opt/cni/bin/loopback ]; then
          mkdir -p /opt/cni/bin
          wget -qO /tmp/cni.tgz "https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz"
          tar -xzf /tmp/cni.tgz -C /opt/cni/bin ./loopback && rm -f /tmp/cni.tgz
        fi
        # Start the Rust CRI daemon (the container engine) in the background and
        # wait for its socket before launching k0s, so the kubelet's first CRI
        # dial succeeds.
        containerd-rs --config /etc/containerd-rs.toml >/var/log/containerd-rs.log 2>&1 &
        for i in $(seq 1 60); do [ -S /run/containerd-rs.sock ] && break; sleep 1; done
        [ -S /run/containerd-rs.sock ] || { echo "containerd-rs socket never appeared"; tail -n 40 /var/log/containerd-rs.log; exit 1; }
        # --cri-socket remote:... makes k0s cede the CRI to containerd-rs (it does
        # NOT launch its own containerd). provider=custom -> no built-in CNI.
        exec k0s controller --config=/etc/k0s/k0s.yaml --enable-worker --no-taints --cri-socket remote:unix:///run/containerd-rs.sock
```

- [ ] **Step 5: Validate compose parses with the build wiring**

Run:
```bash
docker compose -p k0s-rhino-cdrsfl -f stacks/k0s-rhino-containerdrs-crun-flannelrs/docker-compose.yml config -q && echo OK
```
Expected: `OK`. (Full bring-up is gated in Task 6, after the config file exists.)

- [ ] **Step 6: Commit**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add -A stacks/k0s-rhino-containerdrs-crun-flannelrs
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "feat(k0s-rhino-containerdrs-crun-flannelrs): bake containerd-rs v0.1.3 + external-CRI entrypoint

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: containerd-rs daemon config

A self-documenting TOML pinning the load-bearing daemon keys. Values match containerd-rs v0.1.3 defaults (so behavior is unchanged if the file is absent), but explicit config documents the contract and guards against upstream default drift.

**Files:**
- Create: `stacks/k0s-rhino-containerdrs-crun-flannelrs/config/containerd-rs.toml`

**Interfaces:**
- Consumes: mounted at `/etc/containerd-rs.toml` by Task 2's compose change.
- Produces: CRI socket `/run/containerd-rs.sock`, crun runtime, CNI at `/etc/cni/net.d` + `/opt/cni/bin`.

- [ ] **Step 1: Write `config/containerd-rs.toml`**

```toml
# containerd-rs (Rust CRI) daemon config for the k0s node. Mounted AS
# /etc/containerd-rs.toml; the entrypoint runs `containerd-rs --config` against it.
# Values mirror containerd-rs v0.1.3 defaults — explicit here to document the
# contract the kubelet + flannel-rs depend on. Re-check on a containerd-rs bump.
root = "/var/lib/containerd-rs"
state = "/run/containerd-rs"
# Must match --cri-socket remote:unix://... in the compose entrypoint.
cri_socket = "/run/containerd-rs.sock"
stream_server_address = "127.0.0.1:10010"

[cri]
# Pullable from a registry (containerd-rs has no local-image load path).
sandbox_image = "registry.k8s.io/pause:3.10"
# crun is the OCI runtime; containerd-rs shells out to it directly.
default_runtime_name = "crun"
runtime_type = "io.containerd.crun.v2"
snapshotter = "overlayfs"
# cgroupfs (NOT systemd) — matches the k0s kubelet driver under `cgroup: host`,
# same as PR #10's containerd config.
systemd_cgroup = false
# Where flannel-rs hostPath-installs its conflist + plugins; containerd-rs reads
# the lexically-first *.conflist here and execs plugins from cni_bin_dir.
cni_conf_dir = "/etc/cni/net.d"
cni_bin_dir = "/opt/cni/bin"
```

- [ ] **Step 2: Confirm the keys parse against containerd-rs's schema**

Cross-check every key/section above against `crates/containerd-rs/src/config.rs` in the containerd-rs checkout (`Config` = `root`/`state`/`cri_socket`/`stream_server_address`/`cri`; `CriConfig` = `sandbox_image`/`default_runtime_name`/`runtime_type`/`snapshotter`/`systemd_cgroup`/`registry_config_path`/`cni_conf_dir`/`cni_bin_dir`). All keys used here exist; omitted keys (`registry_config_path`) fall back to defaults via `#[serde(default)]`.

Run:
```bash
grep -E 'pub (root|state|cri_socket|stream_server_address|cri|sandbox_image|default_runtime_name|runtime_type|snapshotter|systemd_cgroup|cni_conf_dir|cni_bin_dir)' \
  /home/jones/PhpstormProjects/containerd-rs/crates/containerd-rs/src/config.rs
```
Expected: each field name appears (proves the TOML keys are valid).

- [ ] **Step 3: Commit**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add stacks/k0s-rhino-containerdrs-crun-flannelrs/config/containerd-rs.toml
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "feat(k0s-rhino-containerdrs-crun-flannelrs): containerd-rs daemon config

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Pin flannel-rs to v0.1.3

**Files:**
- Modify: `stacks/k0s-rhino-containerdrs-crun-flannelrs/flannel-rs.yaml`

**Interfaces:**
- Consumes: nothing new.
- Produces: flannel-rs DaemonSet pulling `ghcr.io/indyjonesnl/flannel-rs:0.1.3`.

- [ ] **Step 1: Pin the image tag**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack/stacks/k0s-rhino-containerdrs-crun-flannelrs
sed -i 's#ghcr.io/indyjonesnl/flannel-rs:latest#ghcr.io/indyjonesnl/flannel-rs:0.1.3#g' flannel-rs.yaml
```

- [ ] **Step 2: Verify the pin (and that IfNotPresent is intact)**

Run:
```bash
grep -nE 'image:.*flannel-rs|imagePullPolicy' stacks/k0s-rhino-containerdrs-crun-flannelrs/flannel-rs.yaml
```
Expected: image shows `:0.1.3`; `imagePullPolicy: IfNotPresent` present (NOT `Never`). No remaining `:latest`.

- [ ] **Step 3: Commit**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add stacks/k0s-rhino-containerdrs-crun-flannelrs/flannel-rs.yaml
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "feat(k0s-rhino-containerdrs-crun-flannelrs): pin flannel-rs v0.1.3

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Rewrite smoke engine-verification for containerd-rs

PR #10's smoke verifies crun via `crun --root /run/containerd/runc/k8s.io list` (k0s's containerd state path) and never checks the CRI identity. Under containerd-rs the crun root is `/var/run/containerd-rs/crun`, and we can now prove the CRI itself is containerd-rs via the node's reported runtime. Update the verify block.

**Files:**
- Modify: `stacks/k0s-rhino-containerdrs-crun-flannelrs/smoke/run.sh`

**Interfaces:**
- Consumes: a running node (Task 6 runs the whole script).
- Produces: a smoke run that asserts rhino datastore + **containerd-rs CRI** + crun OCI + flannel-rs pod IPs.

- [ ] **Step 1: Replace the "verify rhino + crun" group**

Find this block in `smoke/run.sh`:

```bash
echo "::group::verify rhino is the datastore + crun is the OCI runtime"
docker exec "$NODE_CTR" sh -c "cat /proc/*/cmdline 2>/dev/null | tr '\0' '\n' | grep -m1 'etcd-servers=.*$RHINO_IP:2379'" >/dev/null 2>&1 \
  && echo "apiserver --etcd-servers points at rhino ($RHINO_IP:2379)" \
  || fail "apiserver is not using rhino as etcd"
# crun tracks the containers it created; >=1 running proves crun is the OCI runtime.
crun_running="$(docker exec "$NODE_CTR" sh -c 'crun --root /run/containerd/runc/k8s.io list 2>/dev/null | grep -c running')"
[ "${crun_running:-0}" -ge 1 ] && echo "crun is the OCI runtime ($crun_running running containers)" \
  || fail "crun is not running any containers (OCI runtime not crun)"
echo "::endgroup::"
```

Replace it with (adds the containerd-rs CRI assertion; fixes the crun root path):

```bash
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
```

- [ ] **Step 2: Add a pod-IP (flannel-rs) assertion after the DNS group**

flannel-rs gives pods 10.244.x; a host-net fallback would give the node IP. Assert the web pod's IP is in the pod CIDR. Insert immediately before the final `echo "PASS: ..."` line:

```bash
echo "::group::verify flannel-rs pod networking (pod IP in 10.244/16)"
podip="$(kc -n smoke get pods -l app=web -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)"
echo "web pod IP: $podip"
case "$podip" in 10.244.*) echo "pod IP is in the flannel-rs pod CIDR";; *) fail "pod IP '$podip' not in 10.244/16 (CNI fell back to host net?)";; esac
echo "::endgroup::"
```

- [ ] **Step 3: Update the final PASS line wording**

Replace:
```bash
echo "PASS: k0s-rhino-crun-flannelrs smoke (rhino datastore + crun OCI + flannel-rs CNI)"
```
with:
```bash
echo "PASS: k0s-rhino-containerdrs-crun-flannelrs smoke (rhino datastore + containerd-rs CRI + crun OCI + flannel-rs CNI)"
```

- [ ] **Step 4: Shellcheck/lint the script parses**

Run:
```bash
bash -n stacks/k0s-rhino-containerdrs-crun-flannelrs/smoke/run.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 5: Commit**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add stacks/k0s-rhino-containerdrs-crun-flannelrs/smoke/run.sh
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "test(k0s-rhino-containerdrs-crun-flannelrs): smoke asserts containerd-rs CRI + crun root + pod CIDR

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Bring up the stack and make smoke green (integration gate)

This is the failing-test-made-green task: it proves the novel join (k0s external CRI = containerd-rs). Expect to iterate here — this is where the `--cri-socket` wiring is validated.

**Files:**
- Modify (only if bring-up reveals a defect): `docker-compose.yml`, `config/containerd-rs.toml`, `smoke/run.sh`.

**Interfaces:**
- Consumes: Tasks 1–5 deliverables.
- Produces: a green `make smoke` — the evidence the stack works.

- [ ] **Step 1: Run smoke (first attempt — expect to debug)**

Run:
```bash
make -C stacks/k0s-rhino-containerdrs-crun-flannelrs smoke 2>&1 | tee /tmp/cdrsfl-smoke.log
```
Expected on success: `PASS: k0s-rhino-containerdrs-crun-flannelrs smoke (...)`.

- [ ] **Step 2: If it fails, triage with this decision list (systematic-debugging) — do NOT guess-patch**

Bring the stack up without the cleanup trap to inspect, using:
```bash
docker compose -p k0s-rhino-cdrsfl -f stacks/k0s-rhino-containerdrs-crun-flannelrs/docker-compose.yml up -d --build
docker logs k0s-rhino-cdrsfl-cluster 2>&1 | tail -60
docker exec k0s-rhino-cdrsfl-cluster sh -c 'tail -n 60 /var/log/containerd-rs.log'
docker exec k0s-rhino-cdrsfl-cluster sh -c 'k0s kubectl get nodes -o wide; k0s kubectl get pods -A'
```
Likely failure modes and the fix to apply (then re-run Step 1):
- **k0s rejects `--cri-socket` on the controller path** (flag parse error in `docker logs`): set the kubelet endpoint via `k0s.yaml` `spec.workerProfiles[0].values` instead — add `containerRuntimeEndpoint: unix:///run/containerd-rs.sock` (kubelet config key), and drop the `--cri-socket` flag. Re-run.
- **kubelet can't dial the CRI** (`containerRuntimeVersion` empty, kubelet log "connection refused"): confirm the socket exists (`ls -l /run/containerd-rs.sock`) and that containerd-rs didn't exit (check `/var/log/containerd-rs.log`); if k0s mounts a fresh `/run` tmpfs that hides the socket, move the socket+wait to after k0s sets up, or share the path — adjust the entrypoint ordering.
- **node NotReady, pods stuck ContainerCreating** with containerd-rs log "no CNI conflist": flannel-rs hadn't installed the conflist yet — confirm the smoke script applies flannel-rs and waits; if the pod CIDR is unset, the existing `kc patch node ... podCIDR` step covers it.
- **pod IP == node IP** (host-net fallback): loopback plugin missing or CNI bin dir mismatch — verify `/opt/cni/bin/loopback` exists and `cni_bin_dir` in the toml matches.
- **image pull errors for pause/nginx/busybox**: in-container DNS — confirm the resolv.conf-rewrite skip + `dns: [8.8.8.8,1.1.1.1]` are intact (inherited from PR #10).

- [ ] **Step 3: Re-run smoke until green**

Run:
```bash
make -C stacks/k0s-rhino-containerdrs-crun-flannelrs smoke 2>&1 | tail -20
```
Expected: ends with `PASS: ...`. Capture the `containerRuntimeVersion:` and crun-count lines as evidence.

- [ ] **Step 4: Commit any fixes made during bring-up**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add -A stacks/k0s-rhino-containerdrs-crun-flannelrs
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "fix(k0s-rhino-containerdrs-crun-flannelrs): green smoke — k0s external CRI on containerd-rs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(If no fixes were needed, skip the commit.)

---

### Task 7: Per-SIG conformance — run, gate, record results

Run the same gated per-SIG suite as PR #10 and record the real outcome. This is long (~75–90 min full); a subset can be run first to de-risk.

**Files:**
- Modify (only if a script wording/path fix is needed): `conformance/run-sigs.sh`, `conformance/run.sh`.

**Interfaces:**
- Consumes: a green stack (Task 6). The conformance scripts already bring the stack up idempotently and were identifier-renamed in Task 1.
- Produces: per-SIG JUnit + a pass/fail table; recorded counts for the spec/README.

- [ ] **Step 1: De-risk with the fastest gating SIG first (network)**

Run:
```bash
SIGS='network' make -C stacks/k0s-rhino-containerdrs-crun-flannelrs conformance-sigs 2>&1 | tee /tmp/cdrsfl-net.log
```
Expected: the summary table prints `sig-network … [gate]`. If it FAILs, triage per Task 6 Step 2 (most network failures trace to CNI/kube-proxy, not the suite).

- [ ] **Step 2: Run the full gated set**

Run:
```bash
make -C stacks/k0s-rhino-containerdrs-crun-flannelrs conformance-sigs 2>&1 | tee /tmp/cdrsfl-sigs.log
```
Expected: the summary table for api-machinery/apps/auth/network/node/scheduling (autoscaling = info). Script exits 0 only if all GATED sigs are green.

- [ ] **Step 3: Record the real numbers (honesty gate)**

Capture the summary table verbatim from the log. These pass/fail counts go into the spec's results note (Task 8) and the PR body. If a gated SIG has failures attributable to a containerd-rs gap (not a stack misconfig), record it as a known gap — do NOT widen `$SKIP` to manufacture a green; instead note it and decide with the user whether that SIG moves to `$NONGATING` with a documented reason.

Run:
```bash
grep -A12 'conformance summary' /tmp/cdrsfl-sigs.log
```
Expected: the table. Save it for Task 8.

- [ ] **Step 4: Commit any conformance-script fixes**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add -A stacks/k0s-rhino-containerdrs-crun-flannelrs/conformance
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "test(k0s-rhino-containerdrs-crun-flannelrs): per-SIG conformance results

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(Skip if no script changes were needed — the run itself produces no tracked files; `.results/` is gitignored.)

---

### Task 8: CI workflow, README, spec status — ship it

**Files:**
- Create: `.github/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml`
- Modify: `README.md`, `docs/superpowers/specs/2026-06-24-k0s-rhino-containerdrs-crun-flannelrs-design.md`

**Interfaces:**
- Consumes: the validated stack + recorded conformance numbers (Task 7).
- Produces: a PR-ready branch.

- [ ] **Step 1: Create the CI workflow**

Copy PR #10's workflow and retarget it to this stack. Create `.github/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml`:

```yaml
name: k0s-rhino-containerdrs-crun-flannelrs

# k0s single-node cluster with the Rust container engine: indyjonesnl/containerd-rs
# (Rust CRI v1) as the engine, crun as the OCI runtime, flannel-rs as the CNI, and
# indyjonesnl/rhino as the etcd-v3 datastore. Validated by smoke (rhino datastore +
# containerd-rs CRI + crun + flannel-rs + DNS) and per-SIG upstream conformance.
#
# HONEST CAVEAT: like the k0s-rhino base, this runs k0s-in-Docker with `cgroup: host`
# + privileged and builds rhino from a sibling checkout. containerd-rs is a younger
# CRI than Go containerd, so conformance breadth may trail the sibling crun stack;
# a red badge can mean "needs a privileged/self-hosted runner" or a recorded
# containerd-rs gap, not necessarily a stack regression.

on:
  push:
    branches: [main]
    paths:
      - 'stacks/k0s-rhino-containerdrs-crun-flannelrs/**'
      - '.github/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml'
  pull_request:
    paths:
      - 'stacks/k0s-rhino-containerdrs-crun-flannelrs/**'
      - '.github/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml'
  workflow_dispatch:

jobs:
  conformance:
    runs-on: ubuntu-latest
    timeout-minutes: 150
    steps:
      - uses: actions/checkout@v4

      - name: Checkout rhino (into the workspace; actions/checkout can't write outside it)
        uses: actions/checkout@v4
        with:
          repository: indyjonesnl/rhino
          path: rhino-src

      - name: Link rhino to the compose build-context path (sibling of the repo)
        run: ln -sfn "$GITHUB_WORKSPACE/rhino-src" "$(dirname "$GITHUB_WORKSPACE")/rhino"

      - name: Deps
        run: |
          docker --version && docker compose version
          sudo apt-get update && sudo apt-get install -y jq python3 curl

      - name: Up + smoke (rhino datastore + containerd-rs CRI + crun OCI + flannel-rs CNI)
        run: make -C stacks/k0s-rhino-containerdrs-crun-flannelrs all

      - name: Conformance — per-SIG [Conformance] subsets (6 gated, autoscaling info)
        run: make -C stacks/k0s-rhino-containerdrs-crun-flannelrs conformance-sigs

      - name: Upload conformance results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: conformance-results-cdrsfl
          path: stacks/k0s-rhino-containerdrs-crun-flannelrs/.results/
          if-no-files-found: ignore

      - name: Teardown
        if: always()
        run: make -C stacks/k0s-rhino-containerdrs-crun-flannelrs clean
```

- [ ] **Step 2: Add a README row for the new stack**

Find the table row / section listing `k0s-rhino-crun-flannelrs` in `README.md` and add a sibling entry for `k0s-rhino-containerdrs-crun-flannelrs` describing it as "k0s + containerd-rs v0.1.3 (Rust CRI) + crun + flannel-rs + rhino". Match the exact column format of the existing rows (inspect the file first; mirror its structure rather than inventing a format).

- [ ] **Step 3: Append the recorded conformance result to the spec**

Add a short "## 6. Result (validated)" section to `docs/superpowers/specs/2026-06-24-k0s-rhino-containerdrs-crun-flannelrs-design.md` with the smoke evidence (the `containerRuntimeVersion` string + crun count) and the per-SIG table captured in Task 7. State pass counts honestly, including any recorded containerd-rs gap and any SIG moved to non-gating with its reason.

- [ ] **Step 4: Validate the workflow YAML parses**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml')); print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **Step 5: Commit**

```bash
cd /home/jones/PhpstormProjects/rustified-kubernetes-stack
git add .github/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml README.md docs/superpowers/specs/2026-06-24-k0s-rhino-containerdrs-crun-flannelrs-design.md
git -c user.name='Indy Jones' -c user.email='development@trucks.nl' commit -m "ci(k0s-rhino-containerdrs-crun-flannelrs): workflow + README + validated results

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Push + open PR (only when the user asks)**

Per repo policy, push uses the public Indy Jones identity (the pre-push hook blocks the private one). Open the PR against `main`, stacked on PR #10, with the smoke + conformance evidence in the body. Do this only on the user's go-ahead.

---

## Notes for the implementer

- **Primary risk = Task 6** (k0s `--cri-socket` external CRI). Everything before it is mechanical; that step is where the design is proven. Budget debugging time there and use systematic-debugging, not guess-patching.
- **Don't touch containerd-rs source.** Gaps are recorded as upstream follow-ups (see the spec). The stack consumes v0.1.3 as published.
- **`.bin/` and `.results/` are gitignored** (inherited `.gitignore`); conformance artifacts are not committed.
- **rhino is built from `../../../rhino`** (a sibling checkout); the compose context path is inherited unchanged from PR #10. CI symlinks it into the workspace.
