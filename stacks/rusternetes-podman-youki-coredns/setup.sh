#!/usr/bin/env bash
# Install youki, configure rootful podman to use it, create the pod network,
# and build the Rusternetes all-in-one + in-tree kubectl. Rootful (uses sudo).
set -euo pipefail

YOUKI_VERSION="0.6.0"
YOUKI_SHA256="e920231ee35a157d48e267611a00c9d5f75b60b003818aa571dda04ca9196e59"
YOUKI_URL="https://github.com/youki-dev/youki/releases/download/v${YOUKI_VERSION}/youki-${YOUKI_VERSION}-x86_64-gnu.tar.gz"

# Resolve paths from the script location (robust under `make -C`, which sets cwd to
# the stack dir). Rusternetes source: explicit RUSTERNETES_SRC > sibling checkout > clone.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="${RUSTERNETES_SRC:-}"
if [ -z "$SRC" ]; then
  if [ -d "$REPO_ROOT/../rusternetes/.git" ]; then SRC="$(cd "$REPO_ROOT/../rusternetes" && pwd)"; else SRC="$REPO_ROOT/.rusternetes-src"; fi
fi

echo "==> podman present?"
command -v podman >/dev/null || { sudo apt-get update && sudo apt-get install -y podman; }
podman --version

if [ -x /usr/local/bin/youki ] && /usr/local/bin/youki --version 2>/dev/null | grep -q "${YOUKI_VERSION}"; then
  echo "==> youki ${YOUKI_VERSION} already installed; skipping"
else
  echo "==> install pinned youki ${YOUKI_VERSION}"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/y.tgz" "$YOUKI_URL"
  echo "${YOUKI_SHA256}  $tmp/y.tgz" | sha256sum -c -
  tar xzf "$tmp/y.tgz" -C "$tmp" youki
  sudo install -m 0755 "$tmp/youki" /usr/local/bin/youki
  /usr/local/bin/youki --version
fi

echo "==> rootful podman: default runtime youki + pod network"
if [ -f /etc/containers/containers.conf.d/youki.conf ]; then
  echo "  youki.conf already present; skipping"
else
  sudo mkdir -p /etc/containers/containers.conf.d
  sudo tee /etc/containers/containers.conf.d/youki.conf >/dev/null <<EOF
[engine]
runtime = "youki"
[engine.runtimes]
youki = ["/usr/local/bin/youki"]
EOF
fi
sudo podman network exists rusternetes-network 2>/dev/null || sudo podman network create rusternetes-network 2>/dev/null || echo "(network create skipped/exists)"

# Pin a FRESH clone to the last bollard/Docker-API commit (fork/main HEAD is now CRI and
# breaks these stacks). A pre-existing sibling checkout (../rusternetes) is used as-is.
RUSTERNETES_REF="${RUSTERNETES_REF:-923fec0d8b5727f951c34b1c6488a96838b6c0f9}"
echo "==> build rusternetes all-in-one + in-tree kubectl (src: $SRC)"
if [ ! -d "$SRC/.git" ]; then
  git clone --recurse-submodules https://github.com/indyjonesnl/rusternetes.git "$SRC"
  ( cd "$SRC" && git checkout "$RUSTERNETES_REF" )
fi
( cd "$SRC" && git submodule update --init --recursive && cargo build --release --bin rusternetes --bin kubectl )

echo "$SRC" > "$SCRIPT_DIR/.rusternetes-src-path"
echo "==> setup complete; rusternetes src at $SRC"
