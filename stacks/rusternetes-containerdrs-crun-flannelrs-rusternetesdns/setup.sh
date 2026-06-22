#!/usr/bin/env bash
# Resolve rusternetes (CRI branch) + containerd-rs sources, build containerd-rs --release.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Pinned CRI-era rusternetes commit (fork/build/compose-cri-runtime as of scaffolding).
RUSTERNETES_REF="${RUSTERNETES_REF:-0c38f19c59988284301739d47530daecc4771a1a}"

# Resolve the rusternetes source on the CRI branch.
# The sibling checkout may be on a different branch with uncommitted work, so we do NOT
# touch its working tree: instead we add a detached, non-invasive git worktree pinned to
# RUSTERNETES_REF. Fall back to a fresh pinned clone if the sibling has no git dir.
# An explicit RUSTERNETES_SRC override wins over everything.
RUSTERNETES_SRC="${RUSTERNETES_SRC:-}"
if [ -z "$RUSTERNETES_SRC" ]; then
  RUSTERNETES_SIBLING="$REPO_ROOT/../rusternetes"
  if [ -d "$RUSTERNETES_SIBLING/.git" ]; then
    RUSTERNETES_SRC="$SCRIPT_DIR/.rusternetes-cri"
    if [ ! -d "$RUSTERNETES_SRC" ]; then
      echo "==> add non-invasive rusternetes worktree @ $RUSTERNETES_REF -> $RUSTERNETES_SRC"
      git -C "$RUSTERNETES_SIBLING" worktree add --detach "$RUSTERNETES_SRC" "$RUSTERNETES_REF"
      ( cd "$RUSTERNETES_SRC" && git submodule update --init --recursive )
    fi
    RUSTERNETES_SRC="$(cd "$RUSTERNETES_SRC" && pwd)"
  else
    RUSTERNETES_SRC="$REPO_ROOT/.rusternetes-src"
    git clone --recurse-submodules https://github.com/indyjonesnl/rusternetes.git "$RUSTERNETES_SRC"
    ( cd "$RUSTERNETES_SRC" && git checkout "$RUSTERNETES_REF" && git submodule update --init --recursive )
  fi
fi

CONTAINERD_RS_SRC="${CONTAINERD_RS_SRC:-}"
if [ -z "$CONTAINERD_RS_SRC" ]; then
  if [ -d "$REPO_ROOT/../containerd-rs/.git" ]; then CONTAINERD_RS_SRC="$(cd "$REPO_ROOT/../containerd-rs" && pwd)";
  else CONTAINERD_RS_SRC="$REPO_ROOT/.containerd-rs-src";
       git clone https://github.com/indyjonesnl/containerd-rs.git "$CONTAINERD_RS_SRC"; fi
fi

echo "==> build containerd-rs --release ($CONTAINERD_RS_SRC)"
# Pin the target dir in-tree so the release binary lands at a deterministic path
# ($CONTAINERD_RS_SRC/target/release/containerd-rs) regardless of any ambient
# CARGO_TARGET_DIR in the environment (downstream scripts rely on this path).
CARGO_TARGET_DIR="$CONTAINERD_RS_SRC/target" make -C "$CONTAINERD_RS_SRC" release

echo "$RUSTERNETES_SRC"   > "$SCRIPT_DIR/.rusternetes-src-path"
echo "$CONTAINERD_RS_SRC" > "$SCRIPT_DIR/.containerd-rs-src-path"
echo "==> sources ready: rusternetes=$RUSTERNETES_SRC containerd-rs=$CONTAINERD_RS_SRC"

# --- Task 4: flannel-rs north-star node image (containerd-rs + crun + kubelet) ---
# Build the rusternetes binaries the stack needs, --release, in the worktree (pin
# CARGO_TARGET_DIR so they land at a deterministic path regardless of any ambient
# CARGO_TARGET_DIR):
#   - kubelet: baked into the node image (Dockerfile.node-rs build context)
#   - kubectl: used by smoke/run.sh + conformance/run.sh to talk to the apiserver
echo "==> build kubelet + kubectl --release ($RUSTERNETES_SRC)"
( cd "$RUSTERNETES_SRC" && CARGO_TARGET_DIR="$RUSTERNETES_SRC/target" \
    cargo build --release --bin kubelet --bin kubectl )
cp -f "$RUSTERNETES_SRC/target/release/kubelet" "$SCRIPT_DIR/kubelet"
echo "==> staged kubelet -> $SCRIPT_DIR/kubelet (kubectl at $RUSTERNETES_SRC/target/release/kubectl)"

# Build the node image FROM rusternetes-containerd-rs:dev (built in Task 2). The
# build context is the stack dir (Dockerfile.node-rs + the staged kubelet +
# node-entrypoint.sh). Skip if the base image is absent (Task 2 not run yet).
if docker image inspect rusternetes-containerd-rs:dev >/dev/null 2>&1; then
  echo "==> build node image rusternetes-node-cdrs:dev"
  docker build -t rusternetes-node-cdrs:dev -f "$SCRIPT_DIR/Dockerfile.node-rs" "$SCRIPT_DIR"
  echo "==> node image ready: rusternetes-node-cdrs:dev"
else
  echo "WARN: rusternetes-containerd-rs:dev not found — run Task-2 build first, then re-run setup.sh"
fi
