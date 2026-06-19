# Rustified Kubernetes Stack

Building a Kubernetes stack that uses Rust components wherever a viable one exists.
Design & roadmap: [`docs/rustified-kubernetes-stack.md`](docs/rustified-kubernetes-stack.md).

## Stack CI status

| Stack | Status |
|-------|--------|
| `kind-containerd-youki-coredns` | ![kind-containerd-youki-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kind-containerd-youki-coredns.yml/badge.svg) |
| `rusternetes-podman-youki-coredns` | ![rusternetes-podman-youki-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-podman-youki-coredns.yml/badge.svg) |
| `rusternetes-podman-youki-rusternetesdns` | ![rusternetes-podman-youki-rusternetesdns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/rusternetes-podman-youki-rusternetesdns.yml/badge.svg) |
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
