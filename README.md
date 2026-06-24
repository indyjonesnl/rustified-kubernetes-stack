# Rustified Kubernetes Stack

Building a Kubernetes stack that uses Rust components wherever a viable one exists.
Design & roadmap: [`docs/rustified-kubernetes-stack.md`](docs/rustified-kubernetes-stack.md).

## Stack CI status

| Stack | Status |
|-------|--------|
| `kind-containerd-youki-coredns` | ![kind-containerd-youki-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kind-containerd-youki-coredns.yml/badge.svg) |
| `kind-containerd-crun-coredns` | ![kind-containerd-crun-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kind-containerd-crun-coredns.yml/badge.svg) |
| `rusternetes-podman-youki-coredns` | ![rusternetes-podman-youki-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-podman-youki-coredns.yml/badge.svg) |
| `rusternetes-podman-youki-rusternetesdns` | ![rusternetes-podman-youki-rusternetesdns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-podman-youki-rusternetesdns.yml/badge.svg) |
| `kubernetes-crio` | ![kubernetes-crio](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kubernetes-crio.yml/badge.svg) |
| `kubernetes-cridockerd-docker` | ![kubernetes-cridockerd-docker](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kubernetes-cridockerd-docker.yml/badge.svg) |
| `k0s-rhino` | ![k0s-rhino](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/k0s-rhino.yml/badge.svg) |
| `k0s-rhino-crun-flannelrs` | ![k0s-rhino-crun-flannelrs](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/k0s-rhino-crun-flannelrs.yml/badge.svg) |
| `k0s-rhino-containerdrs-crun-flannelrs` | ![k0s-rhino-containerdrs-crun-flannelrs](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/k0s-rhino-containerdrs-crun-flannelrs.yml/badge.svg) |

> All-green = every documented stack still builds and passes its smoke test. A red
> badge pinpoints which component combination regressed.

## kind-containerd-youki-coredns

Single-node kind cluster whose OCI runtime is **Youki** (the Rust runtime), set as
containerd's default runtime so every pod — including system pods — runs on it.
Youki is driven by containerd's stock Go `runc-v2` shim via the runc `BinaryName`
option (cgroupfs), which sustains full sig-network `[Conformance]` (52/52, 0
failures). The all-Rust shim variant — `containerd-shim-runc-v2-rs` driving Youki —
boots and passes smoke but cannot hold the control plane together under conformance
churn, so this stack runs Youki under the mature Go shim. See the design doc for
that finding.

Requirements: Docker, `kind`, `kubectl`, `make`.

```bash
make -C stacks/kind-containerd-youki-coredns all     # build image, up, smoke, down
# or step by step:
make -C stacks/kind-containerd-youki-coredns image
make -C stacks/kind-containerd-youki-coredns up
make -C stacks/kind-containerd-youki-coredns smoke
make -C stacks/kind-containerd-youki-coredns down
```

## kind-containerd-crun-coredns

Sibling of the youki stack with the OCI runtime swapped for **crun** (the fast C
runtime, default in CRI-O/Podman): stock `kindest/node` + containerd's Go `runc-v2`
shim pointed at a pinned, sha-verified **crun 1.28** binary via `BinaryName`
(cgroupfs), set as containerd's default so every pod runs on crun. The wiring is
identical to the youki stack — only the runtime binary differs — giving a clean
three-way OCI-runtime comparison: **youki (Rust) · crun (C) · runc (Go baselines)**.
Smoke + full sig-network `[Conformance]` (52/52).

Requirements: Docker, `kind`, `kubectl`, `make`.

```bash
make -C stacks/kind-containerd-crun-coredns all     # build image, up, smoke, down
make -C stacks/kind-containerd-crun-coredns conformance   # sig-network [Conformance]
```

## rusternetes-podman-youki-coredns

The north star: the **Rusternetes** Rust control plane + kubelet scheduling pods that
run on **podman + Youki** (kubelet → Docker API → rootful podman → youki), with
**CoreDNS** for cluster DNS. Containerd-less. The smoke test creates a Deployment +
Service, resolves the Service via CoreDNS, and verifies the pod ran on youki.

Requirements: `make`, `sudo` (rootful), a Rust toolchain. youki is pinned + installed
by `setup.sh`; Rusternetes is built from a sibling `../rusternetes` checkout or cloned.

```bash
make -C stacks/rusternetes-podman-youki-coredns all   # install + build + bring up + smoke
```

## rusternetes-podman-youki-rusternetesdns

Same as above, but cluster DNS is the **native Rust `rusternetes-dns`** (the all-in-one's
in-process DNS server) instead of CoreDNS — so the entire stack is Rust except Podman:
Rusternetes → podman → **Youki**, DNS by **rusternetes-dns**. The smoke test resolves a
Service via rusternetes-dns and verifies the pod ran on Youki.

Requirements: `make`, `sudo` (rootful), a Rust toolchain. youki pinned + installed by `setup.sh`.

```bash
make -C stacks/rusternetes-podman-youki-rusternetesdns all
```

## kubernetes-crio

Upstream Kubernetes on **CRI-O** (`minikube --container-runtime=cri-o`, docker driver) —
a baseline for the CRI path: `kubelet → CRI → CRI-O → crun/runc`. The smoke test runs a
Deployment + Service, resolves the Service via CoreDNS, and verifies the node's container
runtime really is CRI-O. (No Youki here — this is the upstream reference the Rusternetes+CRI
stacks will be compared against once Rusternetes' CRI backend lands.)

Requirements: `minikube`, Docker. No sudo (uses your rootless/group docker).

```bash
make -C stacks/kubernetes-crio all
```

## kubernetes-cridockerd-docker

Upstream Kubernetes on **cri-dockerd → Docker** (`minikube --container-runtime=docker`,
which wires cri-dockerd for K8s ≥1.24): `kubelet → CRI → cri-dockerd → Docker → runc`.
Smoke runs a Deployment + Service, resolves via CoreDNS, and verifies the node runtime is
Docker (`docker://…`). The Docker counterpart to the CRI-O baseline.

Requirements: `minikube`, Docker. No sudo.

```bash
make -C stacks/kubernetes-cridockerd-docker all
```

## k0s-rhino

A **k0s** single-node cluster whose datastore is **indyjonesnl/rhino** (a Rust etcd-v3
gRPC server backed by SQLite) instead of k0s's usual kine/embedded etcd. k0s is configured
for an external etcd cluster (`storage.type: etcd` → `externalCluster`) pointed at rhino; the
kube-apiserver stores all cluster state — objects, revisions, watches — in rhino.

The one substantive code change is in rhino: its `h2` transport strictly rejected the etcd
v3.5 client's `:authority: #initially=[...]` pseudo-header (which Go's gRPC server tolerates),
killing every request with `PROTOCOL_ERROR` before app code. A small patch to a vendored `h2`
(`../rhino/third_party/h2`, via `[patch.crates-io]`) drops an unparseable `:authority` instead
of resetting the stream. Everything else is k0s-in-Docker plumbing captured in the compose/k0s
config (static rhino IP, `cgroup: host`, `--enable-worker --no-taints` so external etcd is
honored, eviction thresholds disabled, coredns `forward` upstream fix).

Conformance reflects what was replaced — **etcd**:
- `make -C stacks/k0s-rhino conformance` runs the sig-api-machinery configmap **Watchers**
  `[Conformance]` spec (add/update/delete watch notifications — etcd's core watch+revision
  contract), green against the rhino-backed apiserver.
- `FOCUS='\[sig-node\] Pods.*\[NodeConformance\]' make -C stacks/k0s-rhino conformance` runs
  the sig-node Pods lifecycle specs (8/8 green: create/update/remove, readiness gates, service
  env vars, host IP) — real pod state + watches driven through rhino as a load proof.
  (`[Slow]` is skipped by default; drop it from `SKIP` for the full sig-node suite.)

Requirements: Docker, `make`. No sudo.

```bash
make -C stacks/k0s-rhino all          # up + smoke
make -C stacks/k0s-rhino conformance  # etcd-responsibility conformance (watch)
```

## k0s-rhino-crun-flannelrs

The same k0s-on-rhino cluster, but with k0s's default runtime parts swapped: **rhino**
(datastore, Rust) + **crun** (OCI runtime — a lightweight C runc replacement, via the
containerd `runc-v2` shim's `BinaryName`) + **flannel-rs** (CNI, Rust). The container engine
is k0s's bundled **stock Go containerd 1.7.32** (not containerd-rs — that's a separate stack).
k0s still runs kube-proxy and coredns, so only the OCI runtime and pod networking change. The crun swap is a self-contained
`/etc/k0s/containerd.toml` (k0s's generated CRI config verbatim + `BinaryName → /usr/local/bin/crun`);
flannel-rs is deployed as a DaemonSet with `network.provider: custom`, plus the standard
`loopback` CNI plugin (containerd's first per-pod CNI call — flannel-rs ships only its own
plugins) installed in the node entrypoint.

`make -C stacks/k0s-rhino-crun-flannelrs conformance-sigs` runs upstream `[Conformance]`
subsets grouped by SIG (cluster brought up once, one focus + JUnit gate per sig). On **k8s
v1.35.5** (`[Serial]`/`[Disruptive]`/`[Flaky]`/`[Slow]` skipped):

| SIG | `[Conformance]` passed | gating |
|---|---|---|
| sig-node | 102 | gate |
| sig-api-machinery | 85 | gate |
| sig-apps | 48 | gate |
| sig-network | 47 | gate |
| sig-auth | 10 | gate |
| sig-scheduling | 2 | gate |
| sig-autoscaling | 0 | info |

**294 passed, 0 failed** across the six gated SIGs. sig-autoscaling is non-gating: all its
`[Conformance]` specs are `[Slow]`/`[Serial]` HPA tests needing metrics-server, so 0 run on
this single-node stack — it is still listed and reported (`passed=0`, info) rather than gated.

Requirements: Docker, `make`. No sudo.

```bash
make -C stacks/k0s-rhino-crun-flannelrs all               # up + smoke (rhino + crun + flannel-rs + DNS)
make -C stacks/k0s-rhino-crun-flannelrs conformance-sigs  # per-SIG [Conformance] subsets
SIGS='node network' make -C stacks/k0s-rhino-crun-flannelrs conformance-sigs  # subset
```

## k0s-rhino-containerdrs-crun-flannelrs

One layer deeper than the sibling stack above: the container engine is replaced with
**containerd-rs v0.1.3** (the Rust CRI), making the entire data path
`k0s kubelet → containerd-rs (CRI, Rust) → crun (OCI)` with **rhino** as the datastore
and **flannel-rs** as the CNI.

The key difference from `k0s-rhino-crun-flannelrs`: k0s is started with
`--cri-socket remote:unix:///run/containerd-rs.sock`, which makes k0s **cede the CRI**
to the external containerd-rs daemon — k0s does not launch or manage its own bundled Go
containerd 1.7.x. containerd-rs is baked into the node image via `Dockerfile.node`
(`COPY --from=ghcr.io/indyjonesnl/containerd-rs:v0.1.3`; the image tag carries the `v`
prefix) and started by the entrypoint before `exec k0s`. The node image also bakes in
`iproute2` because containerd-rs calls `ip netns add` for network namespace creation.
crun is still the OCI runtime (containerd-rs shells out to it directly; no separate shim
binary is needed), and flannel-rs is the CNI DaemonSet pinned at `v0.1.3`.

Validated locally (smoke + sig-network); the full per-SIG suite is exercised by CI.

Smoke results (green): `containerRuntimeVersion: containerd-rs://0.1.3` (kubelet reports
containerd-rs as the CRI), 5 running crun containers, web pod IP `10.244.0.6` (flannel-rs
pod CIDR), DNS resolved, apiserver `--etcd-servers` points at rhino.

Local conformance — sig-network `[Conformance]` on k8s v1.35.5 (`[Serial]`/`[Disruptive]`/
`[Flaky]`/`[Slow]` skipped): **47 passed / 0 failed / 0 errors**. The remaining five SIGs
(api-machinery, apps, auth, node, scheduling) and the non-gating sig-autoscaling run in
CI via the workflow above.

Requirements: Docker, `make`. No sudo.

```bash
make -C stacks/k0s-rhino-containerdrs-crun-flannelrs all               # up + smoke
make -C stacks/k0s-rhino-containerdrs-crun-flannelrs conformance-sigs  # per-SIG [Conformance] subsets
```
