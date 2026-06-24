# Stack: `k0s-rhino-containerdrs-crun-flannelrs` — design

Date: 2026-06-24
Status: design (fork of `k0s-rhino-crun-flannelrs`, PR #10)

## 1. Goal

Push the "Rust where possible" thesis on the k0s path one layer deeper than PR #10:
replace k0s's bundled **Go containerd 1.7.x** with **containerd-rs v0.1.3** (the Rust
CRI), keeping the rhino datastore and flannel-rs CNI. This makes the *container
engine itself* Rust — the one remaining Go component in the data path.

| Layer | `k0s-rhino-crun-flannelrs` (PR #10) | this stack | change |
|-------|-------------------------------------|-----------|--------|
| Datastore | **rhino** (Rust etcd-v3) | rhino | (kept) |
| **Container engine** | **k0s bundled Go containerd 1.7.x** | **containerd-rs v0.1.3** (Rust CRI v1) | **swap** |
| OCI runtime | crun (via containerd runc-v2 shim) | crun (containerd-rs shells out directly) | (kept; wired differently) |
| CNI | **flannel-rs** (Rust) | flannel-rs **v0.1.3** (pinned) | pin |
| Service proxy | kube-proxy | kube-proxy | (kept) |
| Cluster DNS | coredns | coredns | (kept) |

So: `k0s kubelet → containerd-rs (CRI) → crun (OCI)`, datastore = rhino, pod
networking = flannel-rs, services = kube-proxy, DNS = coredns. Name:
**`k0s-rhino-containerdrs-crun-flannelrs`**.

### Success criteria
Same bar as PR #10: **smoke + gated per-SIG conformance**.
- `make smoke`: rhino is the datastore, **containerd-rs** is the CRI (verify the
  containerd-rs daemon process + its socket serve the kubelet), crun is the OCI
  runtime (`crun list` shows running containers), flannel-rs is the CNI (pods on
  10.244.x, pod-to-pod ping), and a Deployment/Service/DNS round-trip is green.
- `make conformance-sigs`: the **same gated per-SIG structure** as PR #10
  (api-machinery, apps, auth, network, node, scheduling), each with its own
  JUnit + gate.

**Honest caveat:** containerd-rs is a younger CRI than Go containerd. We keep the
same gated structure and the same SKIP/FOCUS knobs, but pass counts may land below
PR #10's 294 and surface containerd-rs gaps. Any spec that fails is reported as-is
and recorded as a candidate upstream follow-up — no faked greens, no silent SKIP
widening to manufacture a pass.

## 2. Why v0.1.3 makes this feasible now

containerd-rs `main` shipped as **v0.1.3** already absorbed every k0s-worker CRI
gap fix that previously lived on the throwaway `containerd-rs-k0sfix` branch
(verify with `git log v0.1.0..main`):
- **crun is the built-in OCI runtime** (PR #26): `DEFAULT_RUNTIME =
  io.containerd.crun.v2`, `cri.default_runtime_name = "crun"`. The daemon **shells
  out to `crun` directly** (`crates/runtime/src/crun.rs`) — it is the daemon-side
  equivalent of `containerd-shim-crun-v2`, so **no separate shim binary** is
  installed; the node needs only the `crun` CLI on PATH.
- **loopback configured via the CNI loopback plugin** (PR #25).
- **caps add/drop honored** as ambient, drops-before-adds (PR #28) — fixes the old
  "capabilities.add ignored" gap that forced flannel to run privileged.
- pod-level cgroup for kubelet QoS reads, synchronous LogPath (`kubectl logs`),
  coded WebSocket close (`kubectl exec`), hostPath bind-source dir creation,
  streamed layer pulls (bounded memory), CNI-failure-fails-sandbox (no host-net
  fallback).

containerd-rs v0.1.3 publishes a **static musl binary** as
`ghcr.io/indyjonesnl/containerd-rs:0.1.3` (`Dockerfile.release`). Static musl runs
natively on the Alpine k0s node — no glibc shim needed (same property that lets the
PR #10 static crun binary run on Alpine). Default CRI socket:
`/run/containerd-rs.sock` (configurable via the daemon's TOML `cri_socket`).

## 3. Build = fork PR #10 + swap the engine

Copy `stacks/k0s-rhino-crun-flannelrs/` → `stacks/k0s-rhino-containerdrs-crun-flannelrs/`
and change:

### 3.1 Node image: add containerd-rs (NEW)
PR #10 ran k0s's image directly and installed crun in the entrypoint. This stack
needs the containerd-rs binary baked in, so add a small `Dockerfile.node`:

```
FROM k0sproject/k0s:v1.35.5-k0s.0
COPY --from=ghcr.io/indyjonesnl/containerd-rs:0.1.3 /usr/local/bin/containerd-rs /usr/local/bin/containerd-rs
```

crun + loopback are still installed in the entrypoint via the existing pinned-wget
flow (crun 1.28, sha `2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42`;
CNI loopback v1.6.2). `iproute2`/`ip` is needed for containerd-rs `create_netns`
(`ip netns add`) — verify it is present on the k0s Alpine node, install if not.
The k0s service in `docker-compose.yml` switches from `image:` to `build:` against
this Dockerfile.

### 3.2 Engine swap: external CRI instead of k0s's containerd (NEW)
Entrypoint wrapper (replaces PR #10's crun-drop-in approach):
1. machine-id + skip the resolv.conf rewrite (kept from PR #10).
2. install crun + loopback (kept).
3. start the Rust CRI daemon in the background:
   `containerd-rs --config /etc/containerd-rs.toml &` and wait for its socket.
4. `exec k0s controller --config=/etc/k0s/k0s.yaml --enable-worker --no-taints
   --cri-socket remote:unix:///run/containerd-rs.sock`.

`--cri-socket` makes k0s **cede the CRI** to the external daemon — k0s does NOT
launch or manage its own containerd. Consequently PR #10's
`/etc/k0s/containerd.toml` crun drop-in is **removed** (it configured k0s's
containerd, which no longer runs).

`/etc/containerd-rs.toml` (new) sets:
- `cri_socket = "/run/containerd-rs.sock"` (matches `--cri-socket`),
- CNI conf dir `/etc/cni/net.d` + bin dir `/opt/cni/bin` (where flannel-rs installs),
- crun runtime (defaults: `default_runtime_name = "crun"`, `io.containerd.crun.v2`).

Mounts: replace the `containerd-crun.toml` mount with `containerd-rs.toml`.

### 3.3 flannel-rs pin (CNI)
Same `flannel-rs.yaml` DaemonSet as PR #10, image pinned
`ghcr.io/indyjonesnl/flannel-rs:0.1.3` (was `:latest`). `network.provider: custom`
in `k0s.yaml` unchanged. With v0.1.3's caps fix, re-confirm whether flannel-rs still
needs `privileged: true` for the vxlan link; keep privileged if removal regresses.

### 3.4 Reuse from PR #10 (unchanged)
rhino service + static IP, `cgroup: host`, skip-entrypoint-DNS-rewrite, `dns:`
public resolver, `evictionHard: {}`, the coredns `forward` upstream fix, the rhino
h2 `:authority` dependency, `--enable-worker --no-taints`, the smoke/conformance
script skeletons (FOCUS/SKIP knobs, per-SIG loop, JUnit gating). k0s.yaml is
byte-identical except the rhino endpoint IP.

### 3.5 Distinct identifiers (shared Docker daemon)
New compose project (e.g. `k0s-rhino-cdrsfl`), container names, network +
subnet (`172.33.7.0/24`), and host port (e.g. `27443:6443`) distinct from PR #10's
so both stacks coexist on the shared daemon.

## 4. Risks
- **k0s external-CRI wiring** (`--cri-socket remote:unix://…`) — the primary thing
  to prove first. k0s must accept the flag through the embedded worker and skip its
  managed containerd. If the controller path rejects it, fall back to
  `--kubelet-extra-args`/worker profile to set the kubelet's container-runtime
  endpoint. Verify the kubelet connects to containerd-rs (not a phantom containerd).
- **containerd-rs lifecycle inside the k0s container** — it runs as a background
  process, not under k0s supervision. If it dies, the node goes NotReady silently.
  Acceptable for a single-node dev stack; log its stdout/stderr to a file for
  triage.
- **Conformance breadth** — see §1 caveat; younger CRI may cap pass counts. Report
  honestly.
- **flannel-rs PodCIDR / privileged** — flannel-rs reads `Node.Spec.PodCIDR`
  (assigned by the k0s controller-manager from `network.podCIDR`); patch the node if
  absent, as the existing harness does. Re-test privileged removal against v0.1.3.

## 5. Out of scope
Multi-node; the full (ungated) sig suite beyond PR #10's gated set; any containerd-rs
source changes (consume v0.1.3 as published — gaps become upstream follow-ups, not
fixes in this stack).
