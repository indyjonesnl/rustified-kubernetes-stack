#!/usr/bin/env bash
# Run upstream Kubernetes conformance (ginkgo/e2e.test) against the k0s-on-rhino
# cluster. Default focus is the sig-api-machinery configmap Watchers spec — the
# purest reflection of etcd's responsibilities (watch + revisions), served by
# rhino. Override FOCUS to run other suites, e.g.:
#   FOCUS='\[NodeConformance\]' bash conformance/run.sh    # full sig-node
#
# Brings the stack up (idempotent), repairs the in-cluster bits that an upstream
# e2e BeforeSuite gates on (coredns loop), points e2e.test at the apiserver, and
# fails unless ginkgo's own JUnit reports >=1 passed and 0 failed/errored.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$DIR/.." && pwd)"
PROJECT="k0s-rhino"
COMPOSE=(docker compose -p "$PROJECT" -f "$STACK_DIR/docker-compose.yml")
BIN="$STACK_DIR/.bin"
RESULTS="$STACK_DIR/.results"
K8S_VERSION="${K8S_VERSION:-v1.23.17}"     # match k0sproject/k0s:latest
FOCUS="${FOCUS:-should observe add, update, and delete watch notifications on configmaps \\[Conformance\\]}"
SKIP="${SKIP:-\\[Serial\\]|\\[Disruptive\\]|\\[Flaky\\]|\\[Slow\\]}"
KCFG="$RESULTS/admin.kubeconfig"
mkdir -p "$BIN" "$RESULTS"

kc() { docker exec k0s-rhino-cluster k0s kubectl "$@" 2>/dev/null; }
log() { echo "==> $*"; }
fail() { echo "CONFORMANCE FAIL: $*" >&2; exit 1; }

log "bring up stack (idempotent)"
"${COMPOSE[@]}" up -d --build >/dev/null 2>&1 || fail "compose up"

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

log "write kubeconfig -> 127.0.0.1:6443 (skip-tls)"
docker exec k0s-rhino-cluster k0s kubeconfig admin 2>/dev/null \
  | sed -E -e 's#server: https://[^[:space:]]+#server: https://127.0.0.1:6443#' \
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

log "run conformance: FOCUS='$FOCUS'"
JUNIT_DIR="$RESULTS"; rm -f "$JUNIT_DIR"/junit_*.xml
( cd "$BIN" && ./e2e.test \
    --ginkgo.focus="$FOCUS" --ginkgo.skip="$SKIP" \
    --kubeconfig="$KCFG" --provider=local --num-nodes=1 \
    --report-dir="$JUNIT_DIR" --ginkgo.noColor --ginkgo.v ) 2>&1 | tee "$RESULTS/e2e.log"

JUNIT="$(ls -1 "$JUNIT_DIR"/junit_*.xml 2>/dev/null | head -1)"
[ -f "$JUNIT" ] || fail "no JUnit produced (e2e did not run)"
python3 - "$JUNIT" <<'PY' || fail "conformance gate failed"
import sys, xml.etree.ElementTree as ET
ts = ET.parse(sys.argv[1]).getroot()
ts = ts if ts.tag == "testsuite" else ts.find("testsuite")
tests=int(ts.get("tests",0)); fails=int(ts.get("failures",0)); errs=int(ts.get("errors",0))
passed=sum(1 for tc in ts.findall("testcase")
           if tc.find("skipped") is None and tc.find("failure") is None and tc.find("error") is None)
print(f"JUnit: tests={tests} passed={passed} failures={fails} errors={errs}")
sys.exit(0 if (fails==0 and errs==0 and passed>=1) else 1)
PY
echo "PASS: k0s-rhino conformance (FOCUS reflects etcd's responsibilities via rhino)"
