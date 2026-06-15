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
| **B — Rusternetes-centric** *(chosen)* | Rusternetes kubelet → Docker API → Podman → Youki | Rusternetes | No | Control plane ~94% conformant; runtime path via Podman |
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

## 5. Iteration Roadmap

Each iteration is independently buildable and testable. Status: ☐ planned · ◐ in progress · ☑ done.

### ☐ Iteration 0 — Reality check / fallback (containerd path)
Stand up the **runs-today** baseline so we have a known-good reference and a fallback
if Path B stalls.
- stock kubelet → containerd → `containerd-runc-shim` (Rust) → Youki.
- Validates Youki itself under a battle-tested CRI before betting on Podman/Rusternetes.
- This is the path that names the originally-requested `containerd-rust-extensions`
  and `containerd-shim-runc-v2-rs` crate. Parked as fallback. Detail in **Appendix A**.
- **Done when:** a pod runs on stock K8s with the Rust shim + Youki, verified via `crictl`.

### ☐ Iteration 1 — Youki under Podman
Prove the north-star runtime foundation in isolation, no Kubernetes yet.
- Install Podman, configure Youki as its OCI runtime (`--runtime youki`).
- Run rootless and rootful pods; confirm Youki executes them.
- **Done when:** `podman run` and `podman pod` work with Youki as the runtime.

### ☐ Iteration 2 — Rusternetes control plane
Single-node Rusternetes control plane, no real workloads yet.
- Deploy apiserver + scheduler + controller-manager on Rhino or SQLite backend.
- Bootstrap via Rusternetes' `bootstrap-cluster.sh` / compose.
- **Done when:** `kubectl` can talk to the apiserver and create/list objects.

### ☐ Iteration 3 — Rusternetes kubelet → Podman → Youki
Wire the node layer to the control plane — the containerd-less, Rust-heavy runtime path.
- Rusternetes kubelet drives Podman (which uses Youki) via Docker API.
- kube-proxy programs service routing.
- **Done when:** a Deployment schedules and runs pods end-to-end with no containerd.

### ☐ Iteration 4 — Rust cluster DNS
Replace CoreDNS with a Rust DNS server.
- Candidate: **Hickory-DNS** (formerly trust-dns). Evaluate Kubernetes
  service-discovery integration (does it speak the k8s DNS spec / need a shim?).
- **Done when:** in-cluster DNS resolution works with no CoreDNS pod.

### ☐ Iteration 5 — Rust CNI / networking
Replace Go CNI plugins.
- Candidate: **Redfannel** (Rust Flannel, from the rk8s project) or other.
- **Done when:** pod-to-pod networking works on a Rust CNI.

### Future / unscheduled
- Rust ingress controller evaluation.
- Rust container image builder / registry (e.g. evaluate options vs BuildKit).
- Observability stack in Rust (metrics/log agents).
- Multi-node cluster hardening.

---

## 6. Open Questions & Risks

- **Rusternetes maturity:** ~94% K8s v1.35 conformance (415/441), no tagged releases,
  continuous-development model. ~6% conformance gap will bite on edge cases. Best for
  single-node / edge, not multi-node production.
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
| Rusternetes | https://github.com/calfonso/rusternetes | Rust K8s control plane + kubelet + proxy |
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
