#!/usr/bin/env bash
# Install youki, configure rootful podman to use it, create the pod network,
# and build the Rusternetes all-in-one + in-tree kubectl. Rootful (uses sudo).
set -euo pipefail

YOUKI_VERSION="0.6.0"
YOUKI_SHA256="e920231ee35a157d48e267611a00c9d5f75b60b003818aa571dda04ca9196e59"
YOUKI_URL="https://github.com/youki-dev/youki/releases/download/v${YOUKI_VERSION}/youki-${YOUKI_VERSION}-x86_64-gnu.tar.gz"

# Rusternetes source: prefer a sibling checkout, else clone the fork.
SRC="${RUSTERNETES_SRC:-}"
if [ -z "$SRC" ]; then
  if [ -d "../rusternetes/.git" ]; then SRC="$(cd ../rusternetes && pwd)"; else SRC="$PWD/.rusternetes-src"; fi
fi

echo "==> podman present?"
command -v podman >/dev/null || { sudo apt-get update && sudo apt-get install -y podman; }
podman --version

echo "==> install pinned youki ${YOUKI_VERSION}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/y.tgz" "$YOUKI_URL"
echo "${YOUKI_SHA256}  $tmp/y.tgz" | sha256sum -c -
tar xzf "$tmp/y.tgz" -C "$tmp" youki
sudo install -m 0755 "$tmp/youki" /usr/local/bin/youki
/usr/local/bin/youki --version

echo "==> rootful podman: default runtime youki + pod network"
sudo mkdir -p /etc/containers/containers.conf.d
sudo tee /etc/containers/containers.conf.d/youki.conf >/dev/null <<EOF
[engine]
runtime = "youki"
[engine.runtimes]
youki = ["/usr/local/bin/youki"]
EOF
sudo podman network create rusternetes-network 2>/dev/null || echo "(network exists)"

echo "==> build rusternetes all-in-one + in-tree kubectl (src: $SRC)"
if [ ! -d "$SRC/.git" ]; then
  git clone --recurse-submodules https://github.com/indyjonesnl/rusternetes.git "$SRC"
fi
( cd "$SRC" && git submodule update --init --recursive && cargo build --release --bin rusternetes --bin kubectl )

echo "$SRC" > "$PWD/.rusternetes-src-path"
echo "==> setup complete; rusternetes src at $SRC"
