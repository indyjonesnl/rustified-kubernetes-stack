#!/usr/bin/env bash
# sig-network [Conformance] via Sonobuoy against the kind-containerd-youki-coredns cluster
# (kubelet -> containerd -> Rust shim -> Youki). Heavier than the smoke; runs on
# workflow_dispatch + a nightly schedule, not on every PR.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(cd "$HERE/.." && pwd)"
IMAGE="${IMAGE:-kind-node-youki:dev}"
CLUSTER="${CLUSTER:-youki}"                # matches kind-config.yaml's name:
FOCUS="${FOCUS:-\\[sig-network\\].*\\[Conformance\\]}"
SKIP="${SKIP:-\\[Serial\\]|\\[Disruptive\\]}"

cleanup() {
  sonobuoy delete --all --wait >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "CONFORMANCE FAIL: $*"; sonobuoy retrieve >/tmp/sonobuoy-fail.tar.gz 2>/dev/null && sonobuoy results /tmp/sonobuoy-fail.tar.gz --mode=detailed 2>/dev/null | grep -iE 'fail' | head -40; exit 1; }

command -v sonobuoy >/dev/null || fail "sonobuoy not installed"

echo "::group::create kind cluster ($IMAGE)"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --image "$IMAGE" --config "$STACK_DIR/kind-config.yaml" --wait 120s || fail "kind create"
kubectl -n kube-system wait --for=condition=Ready pod --all --timeout=120s || true
echo "::endgroup::"

echo "::group::sonobuoy run — sig-network [Conformance]"
echo "focus=$FOCUS  skip=$SKIP"
sonobuoy run --e2e-focus "$FOCUS" --e2e-skip "$SKIP" --wait 2>&1 | tail -25 || fail "sonobuoy run"
echo "::endgroup::"

echo "::group::results"
RES="$(sonobuoy retrieve 2>/dev/null)" || fail "sonobuoy retrieve"
sonobuoy results "$RES"
summary="$(sonobuoy results "$RES")"
echo "$summary" | grep -qE '^Status: +passed' || fail "sig-network conformance did not pass (see results above)"
failed="$(echo "$summary" | awk '/^Failed:/{print $2}')"
[ "${failed:-1}" = "0" ] || fail "sig-network conformance had $failed failures"
echo "::endgroup::"

echo "PASS: kind-containerd-youki-coredns sig-network [Conformance] (0 failures)"
