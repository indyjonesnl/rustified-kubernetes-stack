# Stack: `k0s-rhino-crun-flannelrs` — design

Date: 2026-06-23
Status: design (fork of `k0s-rhino`)

## 1. Goal

A sibling of `k0s-rhino` that replaces two more k0s defaults with
alternative/Rust components, to push the "Rust where possible" thesis on the k0s
path:

| Layer | `k0s-rhino` (base) | this stack | change |
|-------|--------------------|-----------|--------|
| Datastore | **rhino** (Rust etcd-v3) | rhino | (kept) |
| OCI runtime | runc (k0s default) | **crun** | swap |
| CNI | kube-router (k0s default) | **flannel-rs** (Rust) | swap |
| Service proxy | kube-proxy (k0s) | kube-proxy | (kept) |
| Cluster DNS | coredns | coredns | (kept) |

So: `k0s → containerd → crun`, datastore = rhino, pod networking = flannel-rs,
services = kube-proxy, DNS = coredns. Name: **`k0s-rhino-crun-flannelrs`**.

### Success criteria
Same bar as `k0s-rhino`: node Ready, rhino is the datastore, and the **sig-network
`[Conformance]` core subset** passes (Services + DNS + intra-pod networking), now
with pods running on **crun** and pod networking by **flannel-rs**. Also verify a
pod's OCI runtime is crun.

## 2. Build = fork `k0s-rhino` + two swaps

Copy `stacks/k0s-rhino/` → `stacks/k0s-rhino-crun-flannelrs/` and change only:

### 2.1 runc → crun (in k0s's bundled containerd)
k0s ships containerd with runc. crun shares the runc CLI, so point the CRI
runtime's `BinaryName` at crun (same trick as `kind-containerd-crun-coredns`).
In the compose entrypoint wrapper (before `k0s controller`):
- install pinned **crun 1.28** (sha `2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42`,
  prebuilt static from github.com/containers/crun/releases) to `/usr/local/bin/crun`.
- drop a containerd config at the path k0s imports (`/etc/k0s/containerd.d/*.toml`)
  setting the `runc` runtime handler's `options.BinaryName = /usr/local/bin/crun`.
Verify: a workload pod's container is backed by a `crun` process on the node.

### 2.2 kube-router → flannel-rs (CNI)
- `k0s.yaml`: `spec.network.provider: custom` (k0s deploys NO built-in CNI; it
  still deploys **kube-proxy** and **coredns** independently, so Services + DNS are
  unaffected). Keep `podCIDR`/`serviceCIDR`.
- Deploy **flannel-rs** (`ghcr.io/indyjonesnl/flannel-rs`, IfNotPresent) — the
  DaemonSet installs the Rust CNI plugins into `/opt/cni/bin` + conflist into
  `/etc/cni/net.d` on the node (the k0s node container shares one fs across
  containerd+kubelet, so the hostPath install lands where containerd reads — same
  as the containerd-rs flannel-rs harness). flannel-rs reads `Node.Spec.PodCIDR`
  (assigned by the k0s controller-manager from `network.podCIDR`).
- Bring-up order matters: with `provider: custom`, the node stays NotReady until a
  CNI is present, so the smoke/conformance scripts **apply flannel-rs right after
  `up`**, then wait for node Ready, then patch coredns, then run.

### 2.3 Reuse from k0s-rhino (unchanged)
rhino service + static IP, `cgroup: host`, skip-entrypoint-DNS-rewrite, `dns:`
public resolver, `evictionHard: {}`, the coredns `forward` upstream fix, the
rhino h2 `:authority` dependency, kubeconfig/`conformance/run.sh` (FOCUS knob),
the `--enable-worker --no-taints` controller flags.

### 2.4 Distinct identifiers (shared Docker daemon)
New compose project (e.g. `k0s-rhino-crunfl`), container names, network + subnet,
and host ports distinct from `k0s-rhino`'s (26443/… ) so both can coexist.

## 3. Risks
- **k0s `provider: custom`** must be accepted by k0s 1.23 (verify at bring-up; if
  not, fall back to disabling kube-router another way).
- **flannel-rs under crun**: flannel-rs is runtime-agnostic CNI; proven under
  containerd-rs+crun already, so expected fine — verify pod-to-pod.
- **PodCIDR assignment**: ensure the controller-manager assigns `Node.Spec.PodCIDR`
  (set `network.podCIDR`); if absent, patch the node as the flannel harness does.
- crun BinaryName drop-in path/format for k0s's containerd (reference the
  `kind-containerd-crun-coredns` containerd config).

## 4. Out of scope
Multi-node; full sig-network suite (core subset only, matching k0s-rhino).
