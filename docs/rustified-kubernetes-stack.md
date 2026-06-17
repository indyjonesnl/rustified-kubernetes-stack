# Rustified Kubernetes Stack

A living design document for a Kubernetes stack that uses Rust components wherever
a viable one exists. Built for a **homelab / experimentation** context: bleeding-edge
and unproven projects are acceptable, downtime is fine, learning is the goal.

This document is meant to be **extended over time**. Each iteration is its own
appendable section. Maturity claims and project status reflect **June 2026** and
should be re-verified as the ecosystem moves fast.

---

## 1. Vision & Principles

- **Rust where possible, honest where not.** Replace a component with a Rust
  implementation only when one actually exists and can run. Where no Rust option
  exists, keep the Go incumbent and record it as a gap, not a pretend-win.
- **Containerd-less is the target.** The north-star runtime path does not run the
  containerd daemon.
- **Bleeding edge is OK.** Pre-release, WIP, and low-star projects are in scope.
- **Iterative.** Stand the stack up in layers; each iteration is independently
  testable and reversible.
- **No silent magic.** Every component swap is documented with what it replaces,
  its maturity, and its known gaps.

---

## 2. Architecture Decision

Investigation surfaced **two divergent Rust-maximal architectures**, not one. They
do not compose trivially because they take different runtime paths.

| Path | Runtime path | Control plane | Containerd? | Maturity |
|------|--------------|---------------|-------------|----------|
| **A — rk8s-centric** | rk8s CRI server → Youki → Rust shim | rk8s (rks) | No | WIP / bleeding edge |
| **B — Rusternetes-centric** *(chosen)* | Rusternetes kubelet → Docker API → Podman → Youki | Rusternetes | No | Control plane ~99.4% conformant; runtime path via Podman |
| C — Pragmatic fallback | stock kubelet → containerd → Rust shim → Youki | stock K8s | **Yes** | Runs today (see Appendix A / Iteration 0) |

**Chosen north star: Path B (Rusternetes-centric).**

Two consequences of this choice, recorded honestly:

1. **The `containerd-rust-extensions` shims drop out of the north star.** Those
   crates (notably `containerd-runc-shim`) exist *to plug into the containerd
   daemon*. With containerd gone and Podman driving the runtime, they have no role
   in Path B. They survive **only** in the Iteration 0 / Appendix A fallback.
   Youki itself survives — as **Podman's OCI runtime**.
2. **Rusternetes does not replace CoreDNS.** It *deploys* stock CoreDNS during
   bootstrap. "Rust DNS replacing CoreDNS" is therefore a **future iteration goal**
   (Iteration 4), with **Hickory-DNS** as the candidate — not something Rusternetes
   provides today.

---

## 3. Target Architecture (North Star — Path B)

```
                 ┌─────────────────────────────────────────────┐
                 │            Control plane (Rust)              │
                 │  Rusternetes apiserver (Axum)                │
                 │  scheduler · controller-manager (31 ctrls)   │
                 └───────────────┬─────────────────────────────┘
                                 │ state backend:
                                 │ etcd (Go) │ Rhino (Rust etcd-compat) │ SQLite
                                 ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │                          Node (per host)                           │
   │                                                                    │
   │  Rusternetes kubelet (Rust) ──Docker API (bollard)──▶ Podman       │
   │                                                          │ OCI     │
   │  Rusternetes kube-proxy (Rust, iptables)                 ▼         │
   │                                              Youki (Rust OCI rt)   │
   │  DNS: CoreDNS (Go)  ── future ──▶ Hickory-DNS (Rust)               │
   │  CNI: Go plugins    ── future ──▶ Rust CNI (e.g. Redfannel)        │
   └──────────────────────────────────────────────────────────────────┘
```

Data flow for starting a pod (north star):
1. Client → Rusternetes apiserver (HTTPS, RBAC, watch API).
2. Scheduler binds pod to a node; controllers reconcile desired state.
3. Node's Rusternetes kubelet pulls the spec, calls the **Docker API** against
   **Podman** (daemonless, rootful mode for iptables on Linux).
4. Podman launches the container via its OCI runtime, configured to be **Youki**.
5. kube-proxy programs iptables for service routing; CoreDNS answers DNS.

---

## 4. Component Map

Maturity legend: 🟢 production-ish · 🟡 beta/usable · 🟠 WIP/experimental · 🔴 vaporware/none.
"Rust?" = is a Rust implementation used in our stack.

| Layer | Incumbent (Go) | Our choice | Rust? | Maturity | Notes |
|-------|----------------|-----------|:-----:|:--------:|-------|
| OCI runtime | runc | **Youki** v0.6.0 | ✅ | 🟡 | OCI-conformant (50/50), ~30% faster cold start. Runs under Podman as OCI runtime. CNCF Sandbox. |
| Container engine | containerd | **Podman** (daemonless) | ❌ | 🟢 | Go, but daemonless — satisfies "no containerd daemon". Drives Youki. |
| Runc v2 shim | containerd-shim-runc-v2 | *(none in Path B)* | — | — | `containerd-runc-shim` (Rust 🟢) used **only** in Appendix A fallback. |
| CRI server | containerd CRI plugin | *(bypassed)* | ❌ | — | Rusternetes uses Docker API, not CRI. No Rust CRI server in rust-extensions. rk8s has one (🟠) — Path A only. |
| kubelet | kubelet | **Rusternetes kubelet** | ✅ | 🟡 | Docker API via bollard; probes, volumes, init containers, exec/attach. |
| kube-apiserver | kube-apiserver | **Rusternetes apiserver** | ✅ | 🟡 | Axum; watch API, RBAC, JWT, Pod Security Standards. |
| scheduler | kube-scheduler | **Rusternetes scheduler** | ✅ | 🟡 | Affinity, taints/tolerations, topology spread. |
| controller-manager | kube-controller-manager | **Rusternetes controllers** | ✅ | 🟡 | 31 controllers (Deployments, StatefulSets, Jobs, etc.). |
| kube-proxy | kube-proxy | **Rusternetes kube-proxy** | ✅ | 🟡 | iptables; ClusterIP/NodePort/LoadBalancer, session affinity. |
| State store | etcd | **Rhino** (Rust etcd-compat) or SQLite | ✅/❌ | 🟡 | Rhino = Rust etcd-compatible gRPC server; SQLite for all-in-one. etcd remains an option. |
| Cluster DNS | CoreDNS | CoreDNS now → **Hickory-DNS** (future) | ❌→✅ | 🟢→🟠 | Rusternetes ships CoreDNS. Rust swap is Iteration 4. |
| CNI | Flannel/Calico/Cilium | Go now → **Redfannel** (future) | ❌→✅ | 🟢→🟠 | Rust CNI ecosystem immature; evaluate later. |

---

## 5. Stack Roadmap

Each entry is a **named, independently buildable stack** identified by its component
tuple, **not** an iteration number. Naming by composition means:

- Each stack gets its own CI workflow and status badge, so we can always see *which
  exact combination* still works (e.g. `kind+containerd+youki+coredns` green even
  after newer stacks land).
- The diff between stacks is visible in the name — each step swaps one or two
  components, emphasising what changed.

Naming scheme: **key components only** — `cluster-engine-runtime-dns`. The Rust shim
is the runtime layer under Youki and is implied by `youki`. Status: ☐ planned ·
◐ in progress · ☑ done · 🟢 CI green.

### ☑ 🟢 `kind-containerd-youki-coredns` — modern baseline (shipped, CI green)
The **runs-today** Rust-runtime baseline and the reference all later stacks are
diffed against.
- stock kubelet → containerd → `containerd-shim-runc-v2-rs` (Rust) → Youki → CoreDNS.
- Runtime exec path is fully Rust (Rust shim + Youki); no Go runc, no Go shim.
- Names the originally-requested `containerd-rust-extensions` /
  `containerd-shim-runc-v2-rs` crate. Keeps containerd by design (see Appendix A).
- CI: `.github/workflows/kind-containerd-youki-coredns.yml`; smoke test exercises
  Deployment, Service+kube-proxy, CoreDNS, ConfigMap/Secret, Job, PVC, exec, probes,
  plus a runtime-verification step confirming containers ran on Youki.
- **Done when:** CI green — cluster boots with Youki as default runtime and the smoke
  test passes locally and in GitHub Actions.

### ☑ 🟢 `rusternetes-podman-youki-coredns` — containerd-less control plane + node (shipped, CI green)
The north star (Path B): containerd dropped entirely. **Validated end-to-end** (local + CI).
- Rusternetes apiserver/scheduler/controllers + kubelet → Docker API (bollard) → Podman → Youki;
  kube-proxy (host iptables) for services; CoreDNS for DNS. All-in-one binary, SQLite, `cni` mode.
- Smoke (in-tree kubectl): Deployment + Service + in-pod DNS lookup resolves via CoreDNS,
  and the pod is verified on Youki (`OCIRuntime=youki`). No containerd.
- Hard-won wiring captured in memory `rusternetes-integration.md` (cert SANs must cover the
  rootful pod-network gateway; CoreDNS manifests applied directly, not via the compose-centric
  bootstrap; `--insecure-skip-tls-verify` flag for the rustls in-tree kubectl).

### ☐ `rusternetes-youki-coredns` — drop Podman (next north-star step)
Remove the last Go piece in the runtime path. **Blocked on a Rusternetes feature:** the kubelet
is hard-wired to bollard (Docker API) with no CRI/direct-OCI backend, and Youki is an OCI runtime
(not a Docker-API daemon), so Podman is currently the required Docker-API↔OCI bridge. Needs a
direct-OCI/youki backend in the kubelet (image pull + namespaces/cgroups/CNI + `youki create/start`).

### ☑ 🟢 `rusternetes-podman-youki-rusternetesdns` — Rust cluster DNS (shipped, CI green)
CoreDNS replaced by the fork's **native `rusternetes-dns`** — the all-in-one's in-process Rust DNS
server. **The original goal: a Rust DNS replacing CoreDNS.** Validated end-to-end (local + CI):
the in-process DNS binds the pod-network gateway `:53` (network created `--disable-dns` so podman's
aardvark-dns doesn't occupy it), a manual `kube-dns` EndpointSlice points kube-proxy at it, and the
smoke test resolves a Service through rusternetes-dns with **no CoreDNS pod**. Pods on Youki.
(Hickory-DNS remains an alternative if a standalone Rust DNS server is ever preferred.)

### ☐ `rusternetes-podman-youki-hickory-rustcni` — Rust networking
Swap Go CNI → Rust CNI.
- Candidate: **Redfannel** (Rust Flannel, from rk8s) or other.
- CI: `rusternetes-podman-youki-hickory-rustcni.yml`.
- **Done when:** CI green — pod-to-pod networking on a Rust CNI.

### CRI-runtime stacks (prove the CRI path)
Demonstrate Kubernetes on CRI runtimes (CRI-O, cri-dockerd→Docker) — baselines for, and
eventually parity with, **Rusternetes once it speaks CRI** (the kubelet's CRI backend is in
progress on the fork; bollard stacks are pinned to the last pre-CRI commit `923fec0d`).
- ◐ `kubernetes-crio` — upstream K8s on **CRI-O** via minikube. *(built; CI pending)*
- ☐ `kubernetes-cridockerd-docker` — upstream K8s on **cri-dockerd → Docker** via minikube.
- ☐ `rusternetes-crio` — Rusternetes (CRI backend) on CRI-O. Gated on the CRI kubelet; pin to a CRI-era SHA (≥ `a43b825d`).
- ☐ `rusternetes-cridockerd-docker` — Rusternetes (CRI backend) on cri-dockerd → Docker. Same gate.

### Future / unscheduled
- Rust ingress controller evaluation.
- Rust container image builder / registry (evaluate vs BuildKit).
- Observability stack in Rust (metrics/log agents).
- Multi-node cluster hardening.

### CI badge matrix
The README carries one badge per stack. All-green = every documented combination still
builds and passes its smoke test on the latest commit. A red badge pinpoints exactly
which component combination regressed.

---

## 6. Open Questions & Risks

- **Rusternetes maturity:** ~99.4% K8s v1.35 conformance, no tagged releases,
  continuous-development model. Residual conformance gap may bite on edge cases. Best
  for single-node / edge, not multi-node production.
- **Rusternetes ↔ Podman coupling:** kubelet talks Docker API via bollard; verify
  Podman's Docker-API compatibility surface covers what Rusternetes kubelet calls.
- **Rootful requirement:** Podman likely needs rootful mode for iptables-based
  kube-proxy on Linux. Confirm impact on the "rootless" ideal.
- **Youki production status:** beta; not officially production-declared. Some prod
  use (Bottlerocket, a few clouds), but treat as experimental here.
- **No Rust CRI in this path:** by choosing Path B we accept a Go-ish engine (Podman).
  A fully containerd-less *and* CRI-based Rust path means rk8s (Path A) — recorded as
  an alternative, not abandoned.
- **DNS spec gap:** Hickory-DNS is a general DNS server, not a k8s-native discovery
  component. Iteration 4 must scope the integration glue.
- **CNI gap:** Rust CNI ecosystem is immature; Iteration 5 may fall back to Go.

---

## 7. Project References (verified June 2026)

| Project | URL | Role |
|---------|-----|------|
| Youki | https://github.com/youki-dev/youki | Rust OCI runtime |
| containerd/rust-extensions | https://github.com/containerd/rust-extensions | Rust shim crates (fallback only) |
| containerd-runc-shim | https://crates.io/crates/containerd-runc-shim | Rust runc v2 shim (fallback only) |
| Rusternetes | https://github.com/indyjonesnl/rusternetes | Rust K8s control plane + kubelet + proxy (~99.4% conformance) |
| rk8s | https://github.com/rk8s-dev/rk8s | Rust CRI server + control plane (Path A alt) |
| Podman | https://github.com/containers/podman | Daemonless container engine (drives Youki) |
| Hickory-DNS | https://github.com/hickory-dns/hickory-dns | Rust DNS server (DNS iteration candidate) |
| conmon-rs | https://github.com/containers/conmon-rs | Rust container monitor (reference) |

---

## Appendix A — Iteration 0 fallback detail (containerd + Rust shim)

The originally-requested path, kept as a runnable baseline and fallback.

```
stock kubelet ──CRI──▶ containerd (Go daemon)
                          │ runtime v2 (ttrpc)
                          ▼
                 containerd-runc-shim  (Rust, from containerd/rust-extensions)
                          │ OCI
                          ▼
                       Youki (Rust OCI runtime)
```

- Configure containerd `config.toml` to use the Rust shim binary as the runtime
  handler, and point it at Youki.
- This is the most proven way to exercise Youki today and isolates Youki bugs from
  Rusternetes/Podman bugs.
- It deliberately **keeps containerd**, so it is *not* the north star — but it is the
  safety net.

---

## Changelog

- **2026-06-15** — Initial document. North star set to Path B (Rusternetes-centric).
  Iteration 0 (containerd fallback) retained. Roadmap iterations 0–5 drafted.
