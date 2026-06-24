#!/usr/bin/env bash
# Run upstream Kubernetes [Conformance] tests grouped by SIG against the
# k0s-on-rhino + crun + flannel-rs cluster. Brings the stack up ONCE, gets the
# node Ready (flannel-rs) and kube-system healthy (coredns), then runs each SIG's
# [Conformance] subset as a SEPARATE focus with its own JUnit report + per-sig
# pass/fail line, and prints a summary table.
#
#   SIGS="node apps network" bash conformance/run-sigs.sh   # subset
#
# Gating: fails the script if any sig NOT in $NONGATING reports failures/errors
# (or matched 0 tests). NONGATING sigs are still run + reported but never fail CI
# because this single-node dev stack lacks the components they exercise
# (autoscaling -> metrics-server/HPA). Override NONGATING="" to hard-gate all.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$DIR/.." && pwd)"
PROJECT="k0s-rhino-cdrsfl"
NODE_CTR="k0s-rhino-cdrsfl-cluster"
APISERVER_PORT=27443
COMPOSE=(docker compose -p "$PROJECT" -f "$STACK_DIR/docker-compose.yml")
K8S_VERSION="${K8S_VERSION:-v1.35.5}"      # match the pinned k0s image (v1.35.5-k0s.0)
BIN="$STACK_DIR/.bin/$K8S_VERSION"         # version-scoped so a version bump re-downloads
RESULTS="$STACK_DIR/.results"
SKIP="${SKIP:-\\[Serial\\]|\\[Disruptive\\]|\\[Flaky\\]|\\[Slow\\]}"
KCFG="$RESULTS/admin.kubeconfig"
SIGS="${SIGS:-api-machinery apps auth autoscaling network node scheduling}"
# sig-autoscaling is non-gating: ALL its [Conformance] specs are [Slow]/[Serial] (HPA, needs
# metrics-server) and get filtered by $SKIP, so 0 run on this single-node stack. It is still
# listed + reported (shows "FAIL: passed=0" as info, not a gate failure). The other 6 gate.
NONGATING="${NONGATING:-autoscaling}"
mkdir -p "$BIN" "$RESULTS"

kc() { docker exec "$NODE_CTR" k0s kubectl "$@" 2>/dev/null; }
log() { echo "==> $*"; }
fail() { echo "CONFORMANCE FAIL: $*" >&2; exit 1; }

log "bring up stack (idempotent)"
"${COMPOSE[@]}" up -d --build >/dev/null 2>&1 || fail "compose up"

# network.provider=custom -> k0s ships no CNI, so the node stays NotReady until we
# deploy flannel-rs. Wait for apiserver + node object, ensure a PodCIDR, then apply.
log "deploy flannel-rs CNI"
for _ in $(seq 1 48); do kc get --raw=/healthz >/dev/null 2>&1 && break; sleep 5; done
for _ in $(seq 1 30); do [ -n "$(kc get nodes --no-headers 2>/dev/null | awk '{print $1}')" ] && break; sleep 5; done
NODE="$(kc get nodes --no-headers 2>/dev/null | awk '{print $1}' | head -1)"
if [ -n "$NODE" ] && [ -z "$(kc get node "$NODE" -o jsonpath='{.spec.podCIDR}' 2>/dev/null)" ]; then
  kc patch node "$NODE" -p '{"spec":{"podCIDR":"10.244.0.0/24","podCIDRs":["10.244.0.0/24"]}}' >/dev/null 2>&1
fi
docker exec -i "$NODE_CTR" k0s kubectl apply -f - < "$STACK_DIR/flannel-rs.yaml" >/dev/null 2>&1 || fail "apply flannel-rs"

log "wait for node Ready"
ready=""
for _ in $(seq 1 40); do
  [ "$(kc get nodes --no-headers 2>/dev/null | awk '{print $2}')" = "Ready" ] && { ready=1; break; }
  sleep 10
done
[ "$ready" = 1 ] || fail "node never became Ready"

# coredns ships 'forward . /etc/resolv.conf'; the node's resolver is local, so the
# loop plugin FATALs. Point it at a real upstream so coredns is Ready (the e2e
# BeforeSuite waits for all kube-system pods). Idempotent.
if kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q '/etc/resolv.conf'; then
  log "patch coredns forward upstream (avoid plugin/loop crash)"
  NEWCORE="$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | sed 's#forward . /etc/resolv.conf#forward . 8.8.8.8 1.1.1.1#')"
  kc -n kube-system patch configmap coredns --type merge \
    -p "$(python3 -c 'import json,sys;print(json.dumps({"data":{"Corefile":sys.stdin.read()}}))' <<<"$NEWCORE")" >/dev/null 2>&1
  kc -n kube-system rollout restart deploy coredns >/dev/null 2>&1
fi

log "wait for all kube-system pods Ready"
kc -n kube-system delete pods --field-selector status.phase=Failed >/dev/null 2>&1
for _ in $(seq 1 30); do
  notready="$(kc get pods -n kube-system --no-headers 2>/dev/null | grep -vcE 'Running|Completed')"
  [ "$notready" = 0 ] && break
  sleep 10
done

log "write kubeconfig -> 127.0.0.1:$APISERVER_PORT (skip-tls)"
docker exec "$NODE_CTR" k0s kubeconfig admin 2>/dev/null \
  | sed -E -e "s#server: https://[^[:space:]]+#server: https://127.0.0.1:$APISERVER_PORT#" \
           -e 's#certificate-authority-data:.*#insecure-skip-tls-verify: true#' > "$KCFG"
[ -s "$KCFG" ] || fail "could not generate kubeconfig"

if [ ! -x "$BIN/e2e.test" ] || [ ! -x "$BIN/ginkgo" ]; then
  log "fetch e2e.test + ginkgo ($K8S_VERSION)"
  curl -fsSL --retry 3 -o "$BIN/ktest.tgz" \
    "https://dl.k8s.io/${K8S_VERSION}/kubernetes-test-linux-amd64.tar.gz" || fail "download e2e.test"
  tar -xzf "$BIN/ktest.tgz" -C "$BIN" --strip-components=3 \
    kubernetes/test/bin/e2e.test kubernetes/test/bin/ginkgo || fail "extract e2e.test"
  rm -f "$BIN/ktest.tgz"; chmod +x "$BIN/e2e.test" "$BIN/ginkgo"
fi

# ---- per-SIG conformance loop ------------------------------------------------
SUMMARY=""
overall=0
for sig in $SIGS; do
  FOCUS="\\[sig-$sig\\].*\\[Conformance\\]"
  JU="$RESULTS/$sig"; rm -rf "$JU"; mkdir -p "$JU"
  log "SIG sig-$sig — FOCUS='$FOCUS'"
  ( cd "$BIN" && ./e2e.test \
      --ginkgo.focus="$FOCUS" --ginkgo.skip="$SKIP" \
      --kubeconfig="$KCFG" --provider=local --num-nodes=1 \
      --report-dir="$JU" --ginkgo.noColor ) > "$RESULTS/e2e-$sig.log" 2>&1 || true

  JUNIT="$(ls -1 "$JU"/junit_*.xml 2>/dev/null | head -1)"
  # Count ONLY real focused specs: every spec the focus matched carries "[Conformance]"
  # in its name. ginkgo also emits synthetic suite nodes ([SynchronizedBeforeSuite] etc.)
  # and a <testcase> per SKIPPED spec — neither has "[Conformance]", so filtering on it
  # gives the true ran/passed/failed (matches ginkgo's "N Passed | M Failed" line).
  read -r p f e < <(python3 - "$JUNIT" <<'PY'
import sys, os, xml.etree.ElementTree as ET
path = sys.argv[1] if len(sys.argv) > 1 else ""
if not path or not os.path.exists(path):
    print("0 0 1"); raise SystemExit
root = ET.parse(path).getroot()
ts = root if root.tag == "testsuite" else root.find("testsuite")
tcs = [tc for tc in ts.findall("testcase") if "[Conformance]" in (tc.get("name") or "")]
passed = sum(1 for tc in tcs
             if tc.find("skipped") is None and tc.find("failure") is None and tc.find("error") is None)
fails  = sum(1 for tc in tcs if tc.find("failure") is not None)
errs   = sum(1 for tc in tcs if tc.find("error") is not None)
print(f"{passed} {fails} {errs}")
PY
)
  gated="gate"; case " $NONGATING " in *" $sig "*) gated="info" ;; esac
  verdict="PASS"
  if [ "$f" != 0 ] || [ "$e" != 0 ] || [ "$p" -lt 1 ]; then
    verdict="FAIL"
    [ "$gated" = gate ] && overall=1
  fi
  printf -v line "  sig-%-15s %-4s  passed=%-3s failures=%-3s errors=%-3s [%s]" \
    "$sig" "$verdict" "$p" "$f" "$e" "$gated"
  echo "$line"
  SUMMARY="$SUMMARY"$'\n'"$line"
done

echo "================ conformance summary (k0s-rhino-crun-flannelrs, $K8S_VERSION) ================"
echo "$SUMMARY"
echo "  (gate = must be green for CI; info = run + reported, non-gating: $NONGATING)"
echo "============================================================================================="
[ "$overall" = 0 ] || fail "one or more GATED sigs failed (see table above)"
echo "PASS: all gated sig [Conformance] subsets green"
