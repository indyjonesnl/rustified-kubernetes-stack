#!/usr/bin/env bash
# =============================================================================
# Turnkey smoke test for the all-Rust Kubernetes stack
#   Rusternetes CRI kubelet -> containerd-rs -> crun  +  flannel-rs  +  rusternetes-dns
#
# This is the stack's `make smoke`. It stands the stack up from clean (or reuses an
# already-running instance) under compose project `crs-cdrs-flannel`, deploys a
# registry-image workload + Service, runs a DNS probe, and asserts the whole
# all-Rust data path end to end. Prints `PASS: ...` and exits 0 on success;
# otherwise dumps diagnostics and exits non-zero.
#
# It codifies the proven manual sequences from Tasks 3-5 (see ../.superpowers/sdd/
# task-{3,4,5}-report.md and the committed compose / Dockerfile / manifests).
#
# -----------------------------------------------------------------------------
# KNOWN LIMITATIONS THIS SCRIPT WORKS AROUND (real containerd-rs gaps, documented
# in the Task-3/4/5 reports — NOT script bugs):
#   * Registry-only images. containerd-rs has no local-image load path, so every
#     pod image (workload, flannel-rs, rusternetes-dns, busybox) is registry-
#     pullable; local-only tags are invisible/unrunnable.
#   * Control plane as compose SIDECARS. kube-scheduler / kube-controller-manager
#     images are local-only, so they can't be static pods under containerd-rs; they
#     run as sidecars on the private net. containerd-rs still runs flannel-rs + the
#     workload pods — the thing actually under test.
#   * kubectl exec / `kubectl logs` are unavailable (CRI 500 / not compiled in).
#     We verify via pod phase + on-disk container logs + containerd-rs logs. This
#     script NEVER calls kubectl exec.
#   * Pod resolv.conf is not auto-injected with the cluster nameserver, so the DNS
#     probe queries the kube-dns ClusterIP (10.96.0.10) directly.
#
# SHARED-DAEMON DISCIPLINE: operates ONLY within project `crs-cdrs-flannel`. Never
# touches other projects (crs-cdrs, co-tenants); teardown is scoped to this project
# (`-p crs-cdrs-flannel ... down -v`), never a broad `docker rm`/grep sweep; never
# mutates tracked shared $RSRC files (uses project-local copies under $FL).
#
# Usage:
#   bash smoke/run.sh                 # idempotent: reuse a healthy cluster, else bring up
#   SMOKE_FRESH=1 bash smoke/run.sh   # force a clean down+up within this project first
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------- paths
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SMOKE_DIR/.." && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/../.." && pwd)"

PROJECT="crs-cdrs-flannel"
FL="$STACK_DIR/.crs-cdrs-flannel"             # project-local runtime state (gitignored)
MANIFESTS="$SMOKE_DIR/manifests.yaml"

# Resolve the rusternetes CRI worktree recorded by setup.sh.
if [ -f "$STACK_DIR/.rusternetes-src-path" ]; then
  RSRC="$(cat "$STACK_DIR/.rusternetes-src-path")"
else
  RSRC="$STACK_DIR/.rusternetes-cri"
fi
[ -d "$RSRC" ] || { echo "FATAL: rusternetes worktree not found at $RSRC — run setup.sh first." >&2; exit 1; }

KUBECTL_BIN="$RSRC/target/release/kubectl"
APISERVER="https://127.0.0.1:36443"
KC=( "$KUBECTL_BIN" --insecure-skip-tls-verify --server="$APISERVER" )
# Always use an empty kubeconfig so only the explicit --server/-skip-tls flags apply.
kubectl() { KUBECONFIG=/dev/null "${KC[@]}" "$@"; }

COMPOSE=( docker compose -p "$PROJECT"
          -f "$RSRC/compose.flannel.yml"
          -f "$STACK_DIR/compose.flannel.containerdrs.yml" )

# Compose interpolation vars used by the override (bind paths + build context).
# Exported unconditionally so EVERY compose call (up, ps, down, diagnostics)
# resolves them — not just the bring-up path.
export STACK_DIR
export CERTS_PATH="$FL/certs"
export KUBELET_VOLUMES_PATH="$FL/volumes"
export EMPTY_MANIFESTS="$FL/manifests-empty"

NODE_CTR="rusternetes-cdrsf-node-1"
# containerd-rs logs are ANSI-colorized; strip escapes before grepping for literals.
# Capture to a string (not a live pipe) so downstream `grep -q` can short-circuit
# without tripping `set -o pipefail` via SIGPIPE on the producer.
node_logs() { docker logs "$NODE_CTR" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
# node_grep <pattern...> — grep node_logs without a pipefail-sensitive live pipe.
node_grep() { local out; out="$(node_logs)"; grep -E "$@" <<<"$out"; }
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CLR=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$YEL" "$CLR" "$*"; }
ok()   { printf '  %s[ok]%s   %s\n' "$GRN" "$CLR" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$RED" "$CLR" "$*" >&2; }

# ----------------------------------------------------------------------------- diagnostics on failure
diagnostics() {
  echo "" >&2
  echo "================= DIAGNOSTICS =================" >&2
  echo "--- compose ps ---" >&2;            "${COMPOSE[@]}" ps 2>&1 | sed 's/^/  /' >&2 || true
  echo "--- pods -A ---" >&2;               kubectl get pods -A -o wide 2>&1 | sed 's/^/  /' >&2 || true
  echo "--- node-1 containerd-rs CNI tail ---" >&2
  node_logs | grep -E "RunPodSandbox|CNI|ErrImage|pull" | tail -20 | sed 's/^/  /' >&2 || true
  echo "==============================================" >&2
}
die() { fail "$*"; diagnostics; exit 1; }

# ----------------------------------------------------------------------------- wait helper
# wait_for <timeout-secs> <description> <cmd...>  — polls cmd until exit 0.
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 3
  done
  return 0
}

# ============================================================================= 1. images / node image
ensure_images() {
  say "Ensuring node image + sources (setup.sh is idempotent)"
  if ! docker image inspect rusternetes-node-cdrs:dev >/dev/null 2>&1; then
    say "node image absent — running setup.sh (builds containerd-rs + kubelet + node image)"
    bash "$STACK_DIR/setup.sh"
  else
    ok "rusternetes-node-cdrs:dev present"
  fi
  docker image inspect rusternetes-node-cdrs:dev >/dev/null 2>&1 \
    || die "rusternetes-node-cdrs:dev still missing after setup.sh"
}

# ============================================================================= 2. project-local artifacts
# Populate $FL with project-local copies so bring-up NEVER writes tracked shared
# $RSRC files. Certs + default SAs come from $RSRC/.rusternetes (gitignored runtime
# state created by the Task-3 bootstrap); if that's absent, generate it via the
# branch's own scripts (the legitimate first-time bootstrap).
stage_artifacts() {
  say "Staging project-local artifacts under $FL"
  mkdir -p "$FL"/{certs,volumes,manifests-empty}

  if [ ! -f "$FL/certs/ca.crt" ]; then
    if [ -f "$RSRC/.rusternetes/certs/ca.crt" ]; then
      cp -a "$RSRC/.rusternetes/certs/." "$FL/certs/"
      ok "copied certs from $RSRC/.rusternetes/certs"
    else
      say "no certs found — generating via branch scripts (first-time bootstrap)"
      ( cd "$RSRC" && mkdir -p .rusternetes/{certs,manifests} && bash scripts/generate-certs.sh )
      cp -a "$RSRC/.rusternetes/certs/." "$FL/certs/"
      ok "generated + copied certs"
    fi
  else
    ok "certs already staged"
  fi

  if [ ! -f "$FL/default-serviceaccounts.yaml" ]; then
    if [ -f "$RSRC/.rusternetes/default-serviceaccounts.yaml" ]; then
      cp -f "$RSRC/.rusternetes/default-serviceaccounts.yaml" "$FL/default-serviceaccounts.yaml"
    else
      ( cd "$RSRC" && bash scripts/generate-default-serviceaccounts.sh )
      cp -f "$RSRC/.rusternetes/default-serviceaccounts.yaml" "$FL/default-serviceaccounts.yaml"
    fi
    ok "staged default-serviceaccounts.yaml"
  else
    ok "default-serviceaccounts.yaml already staged"
  fi

  # bootstrap-cluster.yaml needs no templating in this branch (pinned ClusterIPs);
  # copy read-only into $FL so we never apply straight from the shared tree.
  cp -f "$RSRC/bootstrap-cluster.yaml" "$FL/bootstrap-cluster.rendered.yaml"
}

# ============================================================================= 3. bring-up (idempotent)
cluster_reachable() { kubectl get nodes >/dev/null 2>&1; }

bring_up() {
  if [ "${SMOKE_FRESH:-0}" = "1" ]; then
    say "SMOKE_FRESH=1 — scoped teardown of project $PROJECT"
    "${COMPOSE[@]}" down -v --remove-orphans || true
  fi

  if cluster_reachable && [ "${SMOKE_FRESH:-0}" != "1" ]; then
    ok "cluster already reachable at $APISERVER — reusing (idempotent)"
    return 0
  fi

  say "Bringing up control plane + node-1 under project $PROJECT"
  # (compose interpolation vars are exported at the top of the script.)
  # node-1 + kube-proxy-1 (+ their deps rhino/api-server) + the CP sidecars.
  "${COMPOSE[@]}" up -d node-1 kube-proxy-1 controller-manager scheduler

  say "Waiting for api-server + node-1 Ready"
  wait_for 120 "api-server" cluster_reachable || die "api-server never came up on $APISERVER"
  wait_for 120 "node-1 registered" bash -c \
    'KUBECONFIG=/dev/null '"$KUBECTL_BIN"' --insecure-skip-tls-verify --server='"$APISERVER"' get nodes 2>/dev/null | grep -q node-1' \
    || die "node-1 never registered"
  ok "api-server up, node-1 registered"

  say "Bootstrapping cluster (kubernetes Service + default SAs + kube-dns Service)"
  kubectl apply -f "$FL/default-serviceaccounts.yaml"        >/dev/null
  kubectl apply -f "$FL/bootstrap-cluster.rendered.yaml"     >/dev/null
  ok "bootstrap applied"

  say "Patching node-1 PodCIDR 10.244.0.0/24"
  kubectl patch node node-1 \
    -p '{"spec":{"podCIDR":"10.244.0.0/24","podCIDRs":["10.244.0.0/24"]}}' >/dev/null || true

  # ORDER MATTERS. flannel-rs installs the CNI conflist into /etc/cni/net.d at
  # runtime; any pod whose sandbox is created BEFORE the conflist exists falls back
  # to host-network (containerd-rs logs "no CNI conflist found ... falling back to
  # host network"). A host-networked DNS pod gets the NODE ip, and kube-proxy's
  # ClusterIP DNAT to it does not resolve — so on a clean cluster the DNS probe
  # times out. We therefore apply flannel-rs FIRST, WAIT for the conflist +
  # subnet.env on the node, THEN apply rusternetes-dns so its sandbox gets a real
  # flannel 10.244.x IP.
  say "Applying flannel-rs DaemonSet (ghcr)"
  kubectl apply -f "$STACK_DIR/flannel-rs.containerdrs.yaml" >/dev/null

  say "Waiting for flannel-rs to install the CNI conflist + lease the subnet"
  wait_for 180 "CNI conflist" docker exec "$NODE_CTR" \
    sh -c 'ls /etc/cni/net.d/*.conflist >/dev/null 2>&1' \
    || die "flannel-rs never installed a CNI conflist in /etc/cni/net.d"
  wait_for 180 "flannel subnet" docker exec "$NODE_CTR" test -f /run/flannel/subnet.env \
    || die "flannel-rs never wrote /run/flannel/subnet.env"
  ok "flannel-rs installed the CNI conflist + leased the PodCIDR"

  say "Applying rusternetes-dns (ghcr) now that CNI is ready"
  kubectl apply -f "$STACK_DIR/rusternetes-dns.containerdrs.yaml" >/dev/null

  # Guard against the race anyway: if the DNS pod already landed on host-network
  # (node IP, not 10.244.x) — e.g. it was created in a prior run before CNI — delete
  # it so its Deployment recreates it with CNI available.
  say "Ensuring rusternetes-dns has a flannel pod IP (not host-network)"
  ensure_dns_on_flannel || die "rusternetes-dns never got a flannel 10.244.x IP"

  wait_for 180 "kube-dns flannel endpoint" bash -c \
    'KUBECONFIG=/dev/null '"$KUBECTL_BIN"' --insecure-skip-tls-verify --server='"$APISERVER"' get endpoints kube-dns -n kube-system -o json 2>/dev/null | jq -e "[.subsets[]?.addresses[]?.ip] | map(select(startswith(\"10.244.\"))) | length > 0" >/dev/null' \
    || die "kube-dns endpoint is not a flannel 10.244.x address (DNS on host-network?)"
  ok "rusternetes-dns has a flannel IP; kube-dns endpoint is 10.244.x"
}

# Return 0 once the rusternetes-dns pod is Running with a 10.244.x IP. If it is
# host-networked, delete it once so the Deployment recreates it (CNI now ready).
ensure_dns_on_flannel() {
  local deadline=$(( SECONDS + 180 )) deleted=0 ip phase
  while [ "$SECONDS" -lt "$deadline" ]; do
    # newest rusternetes-dns pod
    local pj name
    pj="$(kubectl get pods -A -o json 2>/dev/null \
          | jq -c 'map(select(.metadata.name|startswith("rusternetes-dns"))) | sort_by(.metadata.creationTimestamp) | last')"
    [ "$pj" = "null" ] || [ -z "$pj" ] && { sleep 3; continue; }
    name="$(jq -r '.metadata.name' <<<"$pj")"
    phase="$(jq -r '.status.phase // "Pending"' <<<"$pj")"
    ip="$(jq -r '.status.podIP // ""' <<<"$pj")"
    case "$ip" in
      10.244.*) [ "$phase" = "Running" ] && return 0 ;;
      "" ) : ;;   # not scheduled yet
      * )  # host-network (node IP) — recreate once
        if [ "$deleted" -eq 0 ]; then
          say "  rusternetes-dns is host-networked ($ip) — recreating with CNI"
          kubectl delete pod "$name" -n kube-system >/dev/null 2>&1 || true
          deleted=1
        fi ;;
    esac
    sleep 3
  done
  return 1
}

# ============================================================================= helpers for assertions
# pod_field <ns> <name> <jq-filter>  — single-pod -o json (works in this harness).
pod_field() { kubectl get pod "$2" -n "$1" -o json 2>/dev/null | jq -r "$3"; }

# on-disk container log path for a pod. The CRI log dir is named
# <ns>_<name>_<uid>, but the in-tree api-server serves uid=null, so we glob the
# directory by <ns>_<name>_* and pick the newest (the just-run probe).
pod_log_path() {  # <ns> <name> <container>
  local ns="$1" name="$2" c="$3"
  local dir
  dir="$(ls -dt "$FL/volumes/pod-logs/${ns}_${name}_"* 2>/dev/null | head -1)"
  [ -n "$dir" ] && echo "$dir/${c}.log"
}

# ============================================================================= 4. deploy workload + assert
PASS=0; CHECKS=0
check() { CHECKS=$((CHECKS+1)); }

run_smoke() {
  # The DNS probe pod has restartPolicy:Never — a leftover Succeeded one from a prior
  # run would never re-execute, so the log check would pass on stale evidence. Delete
  # it first so every run gets a FRESH probe (idempotent reproducibility).
  if kubectl get pod smoke-dns-test >/dev/null 2>&1; then
    say "Deleting prior smoke-dns-test probe pod (force a fresh DNS check)"
    kubectl delete pod smoke-dns-test --wait=true >/dev/null 2>&1 || true
  fi
  # Drop any stale on-disk probe log dirs so the log check reads only this run's.
  rm -rf "$FL/volumes/pod-logs/default_smoke-dns-test_"* 2>/dev/null || true

  say "Applying smoke manifests (Deployment + Service + DNS probe)"
  # The Service's clusterIP is immutable, so a plain re-apply errors once it exists
  # ("spec.clusterIP: field is immutable"). Apply the Service only when absent; the
  # Deployment + probe Pod re-apply cleanly. This keeps the reuse path idempotent.
  if ! kubectl get svc smoke-web >/dev/null 2>&1; then
    kubectl apply -f "$MANIFESTS" >/dev/null
  else
    ok "Service smoke-web exists (immutable clusterIP) — applying workload + probe only"
    # Strip the Service doc; apply the Deployment + probe Pod.
    awk 'BEGIN{RS="\n---\n"} !/kind: Service/{print $0 "\n---"}' "$MANIFESTS" \
      | kubectl apply -f - >/dev/null
  fi

  # --- assertion: Deployment pod reaches Running with a flannel 10.244.x IP ------
  say "Waiting for smoke-web pod Running with a flannel IP"
  wait_for 180 "smoke-web Running" bash -c \
    'KUBECONFIG=/dev/null '"$KUBECTL_BIN"' --insecure-skip-tls-verify --server='"$APISERVER"' get pods -A -o json 2>/dev/null | jq -e "map(select(.metadata.labels.app==\"smoke-web\" and .status.phase==\"Running\")) | length > 0" >/dev/null' \
    || die "smoke-web pod never reached Running"

  local POD POD_IP POD_NODE SANDBOX
  POD="$(kubectl get pods -o json | jq -r '.[] | select(.metadata.labels.app=="smoke-web") | .metadata.name' | head -1)"
  POD_IP="$(pod_field default "$POD" '.status.podIP')"
  POD_NODE="$(pod_field default "$POD" '.spec.nodeName')"

  check
  if [[ "$POD_IP" =~ ^10\.244\. ]]; then
    ok "smoke-web pod $POD Running on $POD_NODE with flannel IP $POD_IP"; PASS=$((PASS+1))
  else
    fail "smoke-web pod IP '$POD_IP' is NOT in the flannel 10.244.x subnet"
  fi

  # --- assertion: pod ran under containerd-rs via CNI (no host-net fallback) -----
  # containerd-rs logs one `RunPodSandbox (CNI) ... ip=10.244.x` per sandbox; a
  # `host network` fallback or a missing line means CNI didn't run for this pod.
  check
  local cni_lines; cni_lines="$(node_grep "RunPodSandbox \(CNI\)" || true)"
  if grep -q "ip=$POD_IP" <<<"$cni_lines"; then
    ok "containerd-rs ran the pod sandbox via CNI (RunPodSandbox (CNI) ip=$POD_IP)"; PASS=$((PASS+1))
  else
    fail "no 'RunPodSandbox (CNI) ip=$POD_IP' in containerd-rs logs (host-network fallback?)"
  fi

  # --- assertion: OCI runtime is crun ------------------------------------------
  check
  local RUNTIME_VER
  RUNTIME_VER="$(docker exec "$NODE_CTR" sh -c '/usr/local/sbin/runc --version 2>/dev/null | head -1' || true)"
  if echo "$RUNTIME_VER" | grep -qi crun; then
    ok "OCI runtime on node-1 is crun ($RUNTIME_VER)"; PASS=$((PASS+1))
  else
    fail "OCI runtime is not crun: '$RUNTIME_VER'"
  fi

  # --- assertion: no Docker/podman daemon in the pod runtime path ---------------
  # The node runtime is containerd-rs (serving CRI); there is no dockerd/podman
  # socket in the kubelet's CRI path. Prove containerd-rs is the CRI server.
  check
  if [ -n "$(node_grep "serving CRI .* over unix socket|containerd-rs starting" || true)" ]; then
    ok "node runtime is containerd-rs serving CRI (no Docker/podman in the pod path)"; PASS=$((PASS+1))
  else
    fail "could not confirm containerd-rs is the CRI server on node-1"
  fi

  # --- assertion: Service gets endpoints ----------------------------------------
  say "Waiting for Service smoke-web to get endpoints"
  wait_for 120 "smoke-web endpoints" bash -c \
    'KUBECONFIG=/dev/null '"$KUBECTL_BIN"' --insecure-skip-tls-verify --server='"$APISERVER"' get endpoints smoke-web -o json 2>/dev/null | jq -e ".subsets[]?.addresses[]?.ip" >/dev/null' \
    || true
  check
  local EP
  EP="$(kubectl get endpoints smoke-web -o json 2>/dev/null | jq -r '.subsets[]?.addresses[]?.ip' | head -1)"
  if [ -n "$EP" ]; then
    ok "Service smoke-web has endpoint $EP"; PASS=$((PASS+1))
  else
    fail "Service smoke-web has no endpoints"
  fi

  # --- assertion: DNS via rusternetes-dns at 10.96.0.10 -------------------------
  say "Waiting for DNS probe pod (smoke-dns-test) to Complete"
  wait_for 150 "dns probe Succeeded" bash -c \
    'KUBECONFIG=/dev/null '"$KUBECTL_BIN"' --insecure-skip-tls-verify --server='"$APISERVER"' get pod smoke-dns-test -o json 2>/dev/null | jq -e ".status.phase==\"Succeeded\"" >/dev/null' \
    || die "smoke-dns-test never reached Succeeded (DNS probe failed) — phase=$(pod_field default smoke-dns-test '.status.phase')"

  check
  local DNS_LOG
  DNS_LOG="$(pod_log_path default smoke-dns-test probe)"
  if [ -n "$DNS_LOG" ] && [ -f "$DNS_LOG" ] && grep -q "SMOKE-DNS-OK" "$DNS_LOG" \
     && grep -q "10.96.0.10" "$DNS_LOG"; then
    ok "rusternetes-dns answered smoke-web via 10.96.0.10 (probe log: $DNS_LOG)"; PASS=$((PASS+1))
  else
    fail "DNS probe log missing SMOKE-DNS-OK / 10.96.0.10 ($DNS_LOG)"
    [ -f "$DNS_LOG" ] && sed 's/^/    | /' "$DNS_LOG" >&2 || echo "    (log not found)" >&2
  fi

  # --- assertion: no CoreDNS ----------------------------------------------------
  check
  if kubectl get pods -A 2>/dev/null | grep -qi coredns; then
    fail "CoreDNS is present (should be replaced by rusternetes-dns)"
    kubectl get pods -A 2>/dev/null | grep -i coredns >&2
  else
    ok "no CoreDNS anywhere (cluster DNS is rusternetes-dns)"; PASS=$((PASS+1))
  fi
}

# ============================================================================= main
say "Smoke: all-Rust stack (containerd-rs + crun + flannel-rs + rusternetes-dns)"
say "project=$PROJECT  apiserver=$APISERVER  RSRC=$RSRC"

ensure_images
stage_artifacts
bring_up
run_smoke

echo ""
if [ "$PASS" -eq "$CHECKS" ]; then
  echo "${GRN}PASS:${CLR} all-Rust stack smoke green — $PASS/$CHECKS assertions passed."
  echo "  containerd-rs+crun ran the workload pod (flannel 10.244.x IP) via CNI;"
  echo "  Service has endpoints; rusternetes-dns resolved via 10.96.0.10; no CoreDNS."
  exit 0
else
  fail "smoke INCOMPLETE — $PASS/$CHECKS assertions passed."
  diagnostics
  exit 1
fi
