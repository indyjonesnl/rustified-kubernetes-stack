#!/usr/bin/env bash
# =============================================================================
# Node-conformance: land ONE upstream Kubernetes [NodeConformance] ginkgo test
# GREEN against the running all-Rust stack
#   Rusternetes CRI kubelet -> containerd-rs -> crun  +  flannel-rs  +  rusternetes-dns
#
# THE PROJECT'S HEADLINE. This does NOT use the branch's podman/Docker-API node-
# conformance harness ($RSRC/scripts/run-node-conformance.sh / compose.node-
# conformance.yml). Instead it points the UPSTREAM e2e.test (real client-go,
# v1.35.0) at OUR running cluster's apiserver via a kubeconfig, and runs a single
# narrow --focus. A real ginkgo summary (>=1 Passed, 0 Failed) + JUnit XML is the
# gate; this is not a hand-rolled check.
#
# -----------------------------------------------------------------------------
# WHY THIS FOCUS (default): "[sig-node] Pods should get a host IP [NodeConformance]"
#   It runs a real pod end to end through the all-Rust data path (kubelet ->
#   containerd-rs -> crun) and asserts the pod reaches the expected STATE via the
#   API (pod.status.hostIP is populated). It is deliberately chosen to dodge the
#   stack's documented gaps:
#     * no kubectl/CRI exec, attach, or port-forward  -> this spec uses none
#     * pod /etc/resolv.conf not auto-injected (DNS)  -> this spec needs no DNS
#     * reading pod logs via the API can be flaky      -> this spec asserts on
#       pod STATUS, never on log content
#   Other status-based node-conformance specs were tried; the container-runtime
#   "should run with the expected status" family FAILS here because it exercises
#   restartPolicy:Always restart accounting that containerd-rs does not yet drive
#   to the expected phase (the container restarts, but the pod never settles into
#   the phase the spec waits 300s for). The host-IP spec is the first that reports
#   1 Passed | 0 Failed, so it's the known-green default.
#
#   Override with FOCUS=... to try another spec (regex, ginkgo --focus syntax).
#
# -----------------------------------------------------------------------------
# SHARED-DAEMON DISCIPLINE: operates ONLY within compose project `crs-cdrs-flannel`
# (via smoke/run.sh for bring-up). Never touches other projects; never does a broad
# `docker rm`/grep; never mutates tracked shared $RSRC files. Test binaries are
# cached in the gitignored .bin/; the kubeconfig + JUnit land under conformance/
# (also gitignored). Nothing here is committed except this script.
#
# Usage:
#   bash conformance/run.sh                 # known-green default focus
#   FOCUS='<ginkgo regex>' bash conformance/run.sh
#   KEEP_RESULTS=1 bash conformance/run.sh  # keep the e2e per-spec artifact dir
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------- paths
CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$CONF_DIR/.." && pwd)"

PROJECT="crs-cdrs-flannel"
BIN_DIR="$STACK_DIR/.bin"
APISERVER="https://127.0.0.1:36443"
KC="$CONF_DIR/.kubeconfig"
RESULTS_DIR="$CONF_DIR/results"
JUNIT="$RESULTS_DIR/junit.xml"

# Upstream test artifacts (must match the branch's K8S_VERSION).
K8S_VERSION="${K8S_VERSION:-v1.35.0}"
TARBALL="kubernetes-test-linux-amd64.tar.gz"
TARBALL_URL="https://dl.k8s.io/${K8S_VERSION}/${TARBALL}"

# The chosen spec. Status-based, no exec/logs/dns. Override via env.
FOCUS="${FOCUS:-Pods should get a host IP \\[NodeConformance\\]}"
# Never run flaky/serial/slow/disruptive variants if a broader FOCUS is supplied.
SKIP="${SKIP:-\\[Flaky\\]|\\[Serial\\]|\\[Slow\\]|\\[Disruptive\\]}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CLR=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$YEL" "$CLR" "$*"; }
ok()   { printf '  %s[ok]%s   %s\n' "$GRN" "$CLR" "$*"; }
die()  { printf '  %s[FAIL]%s %s\n' "$RED" "$CLR" "$*" >&2; exit 1; }

# Resolve the rusternetes CRI worktree (kubectl lives in its target/release).
if [ -f "$STACK_DIR/.rusternetes-src-path" ]; then
  RSRC="$(cat "$STACK_DIR/.rusternetes-src-path")"
else
  RSRC="$STACK_DIR/.rusternetes-cri"
fi
KUBECTL_BIN="$RSRC/target/release/kubectl"

# ============================================================================= 1. cluster up
# Reuse a healthy cluster; otherwise bring it up idempotently via the Task-6 smoke
# bring-up (scoped to project crs-cdrs-flannel). The apiserver is anonymous/skip-
# auth, so a server+skip-tls kubeconfig (no creds) is sufficient.
cluster_reachable() {
  KUBECONFIG=/dev/null "$KUBECTL_BIN" --insecure-skip-tls-verify \
    --server="$APISERVER" get nodes >/dev/null 2>&1
}

ensure_cluster() {
  if cluster_reachable; then
    ok "cluster already reachable at $APISERVER (project $PROJECT) — reusing"
    return 0
  fi
  say "cluster not reachable — bringing up via smoke/run.sh (project $PROJECT)"
  bash "$STACK_DIR/smoke/run.sh" >/dev/null 2>&1 \
    || die "smoke bring-up failed; run 'bash smoke/run.sh' to see why"
  cluster_reachable || die "cluster still not reachable at $APISERVER after bring-up"
  ok "cluster up at $APISERVER"
}

# ============================================================================= 2. kubeconfig
write_kubeconfig() {
  say "Writing project-local kubeconfig ($KC)"
  # The in-tree kubectl requires a (possibly empty) user; client-go is happy with
  # it too. No token/cert needed: the apiserver allows anonymous access. The cert
  # is skipped via insecure-skip-tls-verify, matching the smoke harness.
  cat > "$KC" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $APISERVER
    insecure-skip-tls-verify: true
  name: $PROJECT
users:
- name: admin
  user: {}
contexts:
- context:
    cluster: $PROJECT
    user: admin
    namespace: default
  name: $PROJECT
current-context: $PROJECT
EOF
  KUBECONFIG=/dev/null "$KUBECTL_BIN" --kubeconfig "$KC" get nodes >/dev/null 2>&1 \
    || die "kubeconfig does not work: 'kubectl --kubeconfig $KC get nodes' failed"
  ok "kubeconfig works ($(KUBECONFIG=/dev/null "$KUBECTL_BIN" --kubeconfig "$KC" get nodes --no-headers 2>/dev/null | wc -l) node(s) visible)"
}

# ============================================================================= 3. e2e.test (cached)
fetch_e2e() {
  mkdir -p "$BIN_DIR"
  if [ -x "$BIN_DIR/e2e.test" ] && [ -x "$BIN_DIR/ginkgo" ]; then
    ok "e2e.test + ginkgo already cached in .bin/"
    return 0
  fi
  if [ ! -f "$BIN_DIR/$TARBALL" ]; then
    say "Fetching $TARBALL_URL (cached in .bin/)"
    curl -fL --retry 3 -o "$BIN_DIR/$TARBALL" "$TARBALL_URL" \
      || die "download failed: $TARBALL_URL"
  fi
  say "Extracting e2e.test + ginkgo"
  tar xzf "$BIN_DIR/$TARBALL" -C "$BIN_DIR" --strip-components=3 \
    kubernetes/test/bin/e2e.test kubernetes/test/bin/ginkgo \
    || die "extract failed"
  [ -x "$BIN_DIR/e2e.test" ] && [ -x "$BIN_DIR/ginkgo" ] \
    || die "e2e.test/ginkgo missing after extract"
  ok "e2e.test ($("$BIN_DIR/e2e.test" --version 2>/dev/null)) + ginkgo cached"
}

# ============================================================================= 4. run + gate
run_focus() {
  mkdir -p "$RESULTS_DIR"
  rm -f "$JUNIT"
  # e2e.test chdir's into its own bin dir at startup, so --kubeconfig / --junit-report
  # MUST be absolute paths.
  say "Running ginkgo --focus='$FOCUS' against $APISERVER"
  echo "    skip='$SKIP'"
  local rc=0
  "$BIN_DIR/ginkgo" --no-color --timeout=10m \
    --focus="$FOCUS" --skip="$SKIP" \
    --junit-report="$JUNIT" \
    "$BIN_DIR/e2e.test" -- \
      --kubeconfig="$KC" \
      --provider=local \
      --num-nodes=1 \
      --node-os-distro=custom \
      --prepull-images=false \
    || rc=$?

  [ -f "$JUNIT" ] || die "no JUnit XML produced at $JUNIT"

  # Gate strictly on the JUnit testsuite: failures=0, errors=0, and at least one
  # non-skipped testcase. This is the real ginkgo report, not a string match.
  say "Gating on JUnit ($JUNIT)"
  python3 - "$JUNIT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
suites = [root] if root.tag == 'testsuite' else root.findall('testsuite')
tot_fail = tot_err = ran = 0
passed = []
for ts in suites:
    tot_fail += int(ts.get('failures', 0))
    tot_err  += int(ts.get('errors', 0))
    for tc in ts.iter('testcase'):
        if tc.get('status') == 'skipped':
            continue
        ran += 1
        nm = tc.get('name', '')
        if tc.get('status') == 'passed' and '[It]' in nm:
            passed.append(nm)
print(f"  testsuite: failures={tot_fail} errors={tot_err} ran(non-skipped)={ran}")
for nm in passed:
    print(f"  PASSED SPEC: {nm}")
if tot_fail or tot_err:
    print("GATE FAIL: JUnit reports failures/errors"); sys.exit(1)
if not passed:
    print("GATE FAIL: no [It] spec reported passed (focus matched nothing?)"); sys.exit(1)
print("GATE OK")
PY
  local gate=$?

  if [ "$KEEP_RESULTS" != "1" ]; then
    # e2e.test may leave a per-spec artifact subdir; nothing else to clean.
    :
  fi

  [ "$gate" -eq 0 ] || die "conformance gate failed (see JUnit summary above)"
  [ "$rc" -eq 0 ] || say "(note: ginkgo exit was $rc but JUnit gate passed — proceeding)"
}

# ============================================================================= main
KEEP_RESULTS="${KEEP_RESULTS:-0}"
say "Node-conformance: ONE [NodeConformance] spec against the all-Rust stack"
say "project=$PROJECT  apiserver=$APISERVER  K8S_VERSION=$K8S_VERSION"

[ -x "$KUBECTL_BIN" ] || die "kubectl not found at $KUBECTL_BIN (run setup.sh first)"

ensure_cluster
write_kubeconfig
fetch_e2e
run_focus

echo ""
echo "${GRN}PASS:${CLR} one upstream [NodeConformance] ginkgo spec is GREEN against the"
echo "  all-Rust stack (containerd-rs + crun + flannel-rs + rusternetes-dns)."
echo "  JUnit: $JUNIT"
