# Rustified Kubernetes Stack

Building a Kubernetes stack that uses Rust components wherever a viable one exists.
Design & roadmap: [`docs/rustified-kubernetes-stack.md`](docs/rustified-kubernetes-stack.md).

## Stack CI status

| Stack | Status |
|-------|--------|
| `kind-containerd-youki-coredns` | ![kind-containerd-youki-coredns](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/kind-containerd-youki-coredns.yml/badge.svg) |
| `podman-youki` | ![podman-youki](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/podman-youki.yml/badge.svg) |

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

## podman-youki

Host-level Podman (rootful) running containers and pods on the **Youki** OCI runtime
(pinned v0.6.0) — the runtime foundation for the Rusternetes (Path B) north star.

Requirements: `podman`, `make`, `sudo` (rootful). youki is installed by `setup.sh`.

```bash
make -C stacks/podman-youki all      # install youki + run the smoke test
```
