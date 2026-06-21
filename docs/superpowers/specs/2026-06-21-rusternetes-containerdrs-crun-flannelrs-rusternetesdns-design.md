# Stack: `rusternetes-containerdrs-crun-flannelrs-rusternetesdns` — design

Date: 2026-06-21
Status: design (pending implementation plan)

## 1. Goal

Stand up the most-Rust Kubernetes stack in this repo and prove it works:

| Layer | Choice | Rust? |
|-------|--------|:----:|
| Control plane + kubelet | **Rusternetes** (CRI kubelet backend) | ✅ |
| Node container runtime | **containerd-rs** (`indyjonesnl/containerd-rs`, CRI v1) | ✅ |
| OCI runtime | **crun** (chosen over Youki for speed — §7) | ❌ (C) |
| CNI | **flannel-rs** (`indyjonesnl/flannel-rs`) | ✅ |
| Cluster DNS | **rusternetes-dns** (`crates/dns`) | ✅ |
| State store | SQLite / Rhino (per the compose harness) | — |

Runtime path: `Rusternetes CRI kubelet → containerd-rs → crun`, pod networking by
flannel-rs, DNS by rusternetes-dns. **No podman, no Docker daemon, no Youki, no CoreDNS,
no stock containerd.** Everything Rust except crun and the kernel.

This is the **north star reached in a single stack** (not staged) — possible because the
Rusternetes CRI harness already has flannel-rs and rusternetes-dns integrated (§2).

### Success criteria

1. **Smoke** (Rusternetes in-tree `kubectl`): Deployment + Service up; in-pod DNS lookup of
   the Service resolves via **rusternetes-dns** (no CoreDNS pod); pod verified running under
   **crun** on **containerd-rs** (CRI socket is containerd-rs; a `crun` process backs the
   container); no Docker/podman daemon in the runtime path.
2. **≥1 `[NodeConformance]` (sig-node `[Conformance]`) ginkgo test passes** end-to-end, via
   the branch's existing `run-node-conformance.sh` (upstream `e2e.test`, `--focus` narrowed
   to one cheap node-level test). Headline achievement; full suite is out of scope.

## 2. Why this shape — the harness already exists

The Rusternetes fork branch `build/compose-cri-runtime` already runs a **compose-based,
single-node CRI cluster** that is 90% of this stack:

- `Dockerfile.containerd` bakes the node runtime: *stock* containerd (CRI plugin) + **Youki**
  (via runc `BinaryName`) + Go CNI plugins; serves CRI on `/run/containerd/containerd.sock`
  (a shared named volume). Pins: `CONTAINERD_VERSION=2.2.4`, `RUNC_VERSION=1.2.6`,
  `CNI_VERSION=1.6.2`, `YOUKI_VERSION=0.6.0`.
- `Dockerfile.node` = that runtime base + the Rusternetes kubelet binary, one container,
  `ENV CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock`.
- **flannel-rs** is already the CNI: the node drops its standalone bridge conf and lets the
  flannel-rs DaemonSet install `/etc/cni/net.d` + `/opt/cni/bin` at runtime.
- **rusternetes-dns** is a first-class component: `crates/dns`, `Dockerfile.dns`,
  `bootstrap-dns.yaml`; the kubelet runs with `--cluster-dns 10.96.0.10`.
- `scripts/run-node-conformance.sh` boots the compose cluster and runs upstream `e2e.test`
  focused on `[NodeConformance]` (K8s `v1.35.0`, skip `Flaky|Serial|Slow`). **This exact
  harness is what passed full sig-node on stock containerd + Youki.**

So this stack is **one swap**: replace the *stock containerd + Youki* runtime image with a
**containerd-rs + crun** image. Everything else (CRI kubelet, flannel-rs, rusternetes-dns,
the conformance runner) is reused unchanged.

The **one genuinely novel join**: `Rusternetes CRI kubelet ↔ containerd-rs`. Both speak CRI
v1; first bring-up is where any CRI-surface mismatch shows. flannel-rs is runtime-agnostic
(it is just `/opt/cni/bin` plugins invoked via a conflist) and containerd-rs's `sandbox`
crate runs a CNI chain, so flannel-rs under containerd-rs is expected to work as-is — but it
is a second thing being proven for the first time together (noted as a risk, §7).

## 3. Architecture

```
            ┌────────────────────────────────────────────┐
            │       Rusternetes control plane (Rust)      │
            │  api-server · scheduler · controllers       │
            │  state: SQLite / Rhino (compose harness)    │
            └───────────────────┬────────────────────────┘
                                │
   ┌────────────────────────────────────────────────────────────┐
   │              Node container (compose service)                │
   │                                                              │
   │  Rusternetes CRI kubelet ──CRI v1──▶ containerd-rs           │
   │     CONTAINER_RUNTIME_ENDPOINT=             │ invokes        │
   │       unix:///run/containerd/containerd.sock▼  "runc"=crun   │
   │     (containerd-rs binds THIS path)        crun (C OCI)      │
   │                                                              │
   │  CNI: flannel-rs (DaemonSet installs plugins + conflist)     │
   └────────────────────────────────────────────────────────────┘
   DNS: rusternetes-dns service @ 10.96.0.10 (bootstrap-dns.yaml)
```

Pod start: client → api-server → scheduler binds → CRI kubelet `RunPodSandbox` /
`CreateContainer` / `StartContainer` over the containerd-rs socket → containerd-rs pulls the
image (content store + overlayfs), wires the pod netns via flannel-rs, launches via crun.

## 4. Key wiring decisions

### 4.1 Drop-in socket path
containerd-rs config `cri_socket = "/run/containerd/containerd.sock"` — the exact path the
kubelet already expects. Result: the kubelet, `Dockerfile.node`, and compose need **no
endpoint change**; the only delta is the runtime image build.

### 4.2 crun as the OCI runtime, despite a hardcoded `runc`
containerd-rs hardcodes `runtime::runc::DEFAULT_BIN` (`"runc"`) at ~10 call sites
(`crates/cri/src/server.rs`, `crates/cri/src/streaming.rs`); `CriConfig` has no runtime-binary
field. crun shares the runc CLI, so:

- **(A) Bring-up (chosen):** install pinned crun **as the `runc` binary on the daemon's
  PATH** (e.g. `install crun /usr/local/sbin/runc`), mirroring how `Dockerfile.containerd`
  places `runc`. Zero containerd-rs code change.
- **(B) Clean follow-up (containerd-rs repo):** add `cri.runtime_binary` to `CriConfig` and
  thread it through the call sites (the "overridable for crun/youki" comment promises this).
  Small, upstream-able; do it if convenient, else track as a gap.

crun pin (reuse `kind-containerd-crun-coredns`): `CRUN_VERSION=1.28`,
`SHA256=2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42`, prebuilt static
from `github.com/containers/crun/releases`. No compile.

### 4.3 containerd-rs build
Build `containerd-rs` `--release` from the sibling `../containerd-rs` checkout (or pinned
clone), `make release` → `target/release/containerd-rs`. The runtime image starts from a
slim base, COPYs the binary + crun, writes `config.toml` (cgroupfs, the drop-in socket
path, CNI dirs), and runs the daemon. containerd-rs needs root + a privileged container
(overlayfs, netns, cgroups) — the compose node already runs privileged.

### 4.4 Reuse unchanged
flannel-rs DaemonSet, rusternetes-dns (`bootstrap-dns.yaml`, `--cluster-dns 10.96.0.10`),
the CRI kubelet flags, `run-node-conformance.sh`, the cgroupfs / nested-netns conntrack
workarounds the branch already carries.

## 5. Harness & layout

A stack dir in this repo that **composes the two sibling repos and overrides one service**:

```
stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns/
  Makefile                     # setup / smoke / conformance / clean / all
  setup.sh                     # pin+clone rusternetes (CRI ref) & containerd-rs;
                               #   build containerd-rs --release; build the runtime image
  Dockerfile.containerd-rs     # slim base + containerd-rs binary + pinned crun(as runc)
                               #   + config.toml + entrypoint; VOLUME /run/containerd
  config/
    containerd-rs.config.toml  # cri_socket=/run/containerd/containerd.sock, cgroupfs, CNI dirs
    entrypoint.sh
  compose.containerdrs.yml     # override: point the `containerd` service at our image/build
  smoke/run.sh                 # Deployment+Service, DNS via rusternetes-dns, pod-on-crun proof
  conformance/run.sh           # wraps run-node-conformance.sh with FOCUS=<one test>
```

Run model: `setup.sh` builds artifacts; the stack invokes the branch's
`run-node-conformance.sh` with `EXTRA_COMPOSE_FILES=compose.containerdrs.yml` so the runtime
service uses containerd-rs+crun instead of stock-containerd+Youki. Source resolution follows
the existing pattern: env override > sibling checkout (`../rusternetes`, `../containerd-rs`)
> pinned clone. Pin the rusternetes ref to a CRI-era SHA on `build/compose-cri-runtime`
(record it in `setup.sh`, as other stacks pin `923fec0d`).

## 6. Roadmap

This stack reaches the all-Rust north star directly (single stack). Follow-ups, each its own
spec + CI badge:

- **Youki variant** (`...-youki-...`): flip crun→Youki via the same `runc`-CLI mechanism, for
  an all-Rust-incl-OCI run (the Rust-max purist stack).
- **containerd-rs `runtime_binary` config field** (containerd-rs repo): land decision §4.2(B).
- **Full sig-node**, then **sig-network / sig-storage** suites on this stack.

## 7. Decisions & honest gaps

- **crun over Youki (deliberate):** faster, but the OCI layer is C not Rust. Trade-off
  accepted; Youki remains a one-line swap (§4.2) and is covered by the youki stacks.
- **containerd-rs has no runtime-binary config field** — bring-up uses crun-as-`runc`; clean
  fix tracked as §4.2(B).
- **Two firsts at once:** `CRI kubelet ↔ containerd-rs` AND `flannel-rs under containerd-rs`.
  Bisect aids: containerd-rs is known-good under kubeadm with the Go flannel plugin
  (`ci/cni-node.sh`) and the Rusternetes CRI kubelet is known-good against stock containerd —
  if smoke fails, temporarily (a) point the kubelet at stock containerd, or (b) swap
  flannel-rs for the node image's static bridge conf, to localize the fault.
- **Single node only.** No multi-node VXLAN routing exercised.
- **Scope is one ginkgo test, not the suite.** Full sig-node is a follow-up.
