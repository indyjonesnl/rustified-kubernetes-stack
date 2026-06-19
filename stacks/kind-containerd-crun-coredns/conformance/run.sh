#!/usr/bin/env bash
# sig-network [Conformance] via Sonobuoy against the kind-containerd-crun-coredns
# cluster (kubelet -> containerd -> Go runc-v2 shim -> crun). Heavier than the
# smoke; runs on workflow_dispatch + a nightly schedule, not on every PR.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(cd "$HERE/.." && pwd)"
IMAGE="${IMAGE:-kind-node-crun:dev}"
CLUSTER="${CLUSTER:-crun}"                 # matches kind-config.yaml's name:
FOCUS="${FOCUS:-\\[sig-network\\].*\\[Conformance\\]}"
SKIP="${SKIP:-\\[Serial\\]|\\[Disruptive\\]}"

# Retrieve sonobuoy result tarballs into a temp dir so they never litter the cwd
# (which is the repo root when invoked via `make`).
RESDIR="$(mktemp -d)"
cleanup() {
  sonobuoy delete --all --wait >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  rm -rf "$RESDIR"
}
trap cleanup EXIT
fail() { echo "CONFORMANCE FAIL: $*"; sonobuoy retrieve "$RESDIR" >/dev/null 2>&1 && sonobuoy results "$RESDIR"/*.tar.gz --mode=detailed 2>/dev/null | grep -iE 'fail' | head -40; exit 1; }

command -v sonobuoy >/dev/null || fail "sonobuoy not installed"

echo "::group::create kind cluster ($IMAGE)"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --image "$IMAGE" --config "$STACK_DIR/kind-config.yaml" --wait 120s || fail "kind create"
kubectl -n kube-system wait --for=condition=Ready pod --all --timeout=120s || true
echo "::endgroup::"

echo "::group::sonobuoy run — sig-network [Conformance]"
echo "focus=$FOCUS  skip=$SKIP"
# --wait-output=progress streams test progress instead of blocking silently.
sonobuoy run --e2e-focus "$FOCUS" --e2e-skip "$SKIP" --wait --wait-output=progress 2>&1 | tail -40 || fail "sonobuoy run"
echo "::endgroup::"

echo "::group::results"
RES="$(sonobuoy retrieve "$RESDIR" 2>/dev/null)" || fail "sonobuoy retrieve"
sonobuoy results "$RES"
summary="$(sonobuoy results "$RES")"
# sonobuoy prints one block per plugin (e2e + systemd-logs), so there are multiple
# 'Status:'/'Failed:' lines. Gate on: no plugin in a non-passed state, AND the sum
# of all 'Failed:' counts is zero. (Grabbing a single 'Failed:' line mis-gates.)
echo "$summary" | grep -qE '^Status: +(failed|unknown|running)' && fail "a conformance plugin did not pass (see results above)"
total_failed="$(echo "$summary" | awk '/^Failed:/{s+=$2} END{print s+0}')"
[ "$total_failed" = "0" ] || fail "sig-network conformance had $total_failed failures"
echo "::endgroup::"

echo "PASS: kind-containerd-crun-coredns sig-network [Conformance] (0 failures)"
