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
| `rusternetes-containerdrs-crun-flannelrs-rusternetesdns` | ![rusternetes-containerdrs-crun-flannelrs-rusternetesdns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-containerdrs-crun-flannelrs-rusternetesdns.yml/badge.svg) |
| `kubernetes-crio` | ![kubernetes-crio](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kubernetes-crio.yml/badge.svg) |
| `kubernetes-cridockerd-docker` | ![kubernetes-cridockerd-docker](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kubernetes-cridockerd-docker.yml/badge.svg) |

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

## rusternetes-containerdrs-crun-flannelrs-rusternetesdns

The all-Rust CRI stack: **Rusternetes CRI kubelet → containerd-rs → crun**, with
**flannel-rs** (Rust CNI) and **rusternetes-dns** (Rust DNS). No Docker daemon, no
Podman, no Youki, no CoreDNS, no stock containerd — the node runtime is the Rust
**containerd-rs** serving CRI directly, and crun (the fast C runtime) is the
deliberate OCI choice for speed. This is the same CRI compose harness as the bollard
stacks with **one swap**: the node image is a baked `Dockerfile.node-rs`
(containerd-rs + crun + the CRI kubelet) layered over the base
`compose.flannel.yml` via `compose.flannel.containerdrs.yml` (project
`crs-cdrs-flannel`). The control plane (api-server, rhino, scheduler,
controller-manager, kube-proxy) runs as compose sidecars; flannel-rs and
rusternetes-dns deploy from ghcr.

Proven: `make smoke` passes **7/7** (workload pod gets a flannel `10.244.x` IP via
CNI, runs under crun on containerd-rs, Service has endpoints, rusternetes-dns
resolves at `10.96.0.10`, no CoreDNS), and `make conformance` lands **one** upstream
ginkgo spec green — `[sig-node] Pods should get a host IP [NodeConformance]
[Conformance]` (1 Passed / 0 Failed). crun is C, not Rust; **Youki** is a documented
future variant via the same runc-CLI swap.

Requirements: Docker, `make`, a Rust toolchain, `protobuf-compiler`, `jq`.
containerd-rs and the kubelet are built `--release` by `setup.sh` from sibling
checkouts (`../rusternetes` on the CRI ref, `../containerd-rs`) or pinned clones.

```bash
make -C stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns all          # setup + smoke
make -C stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns conformance  # one [NodeConformance] spec
make -C stacks/rusternetes-containerdrs-crun-flannelrs-rusternetesdns clean        # scoped down -v (project crs-cdrs-flannel only)
```

**Known limitations** (real containerd-rs gaps, found during integration and worked
around honestly — not hidden):
- **Registry-only image pull.** containerd-rs has no local-image load path, so every
  pod image must be registry-pullable; local-only tags are invisible.
- **Control-plane images run as compose sidecars.** The CP images are local-only, so
  they can't be static pods under containerd-rs — they run as sidecars on the private
  net. containerd-rs still runs flannel-rs + the workload pods (the thing under test).
- **`securityContext.capabilities.add` ignored for non-privileged pods**, so the
  flannel-rs pod runs privileged to get its needed capabilities.
- **Node image needs `iproute2`** baked in (containerd-rs does not provide it).
- **`kubectl exec` and single-pod `-o json` (for some pods) are unavailable** (CRI
  500); the smoke harness verifies via pod phase + on-disk logs + containerd-rs logs,
  never via exec.
- **Pod `/etc/resolv.conf` is not auto-injected** with the cluster nameserver, so DNS
  is queried at the kube-dns ClusterIP (`10.96.0.10`) directly.
- **`restartPolicy: Always` phase accounting** is incomplete (the container restarts
  but the pod never settles into the spec's expected phase), so the
  container-runtime "expected status" node-conformance family times out — which is
  why the chosen green spec is the status-based host-IP one.

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
