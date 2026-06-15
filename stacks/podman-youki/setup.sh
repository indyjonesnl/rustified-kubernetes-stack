#!/usr/bin/env bash
set -euo pipefail

YOUKI_VERSION="0.6.0"
YOUKI_SHA256="e920231ee35a157d48e267611a00c9d5f75b60b003818aa571dda04ca9196e59"
YOUKI_URL="https://github.com/youki-dev/youki/releases/download/v${YOUKI_VERSION}/youki-${YOUKI_VERSION}-x86_64-gnu.tar.gz"
DEST="${YOUKI_DEST:-/usr/local/bin/youki}"

echo "==> Checking podman is present"
command -v podman >/dev/null || { echo "FAIL: podman not found (install: sudo apt-get install -y podman)"; exit 1; }
podman --version

echo "==> Downloading youki ${YOUKI_VERSION} (pinned)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/youki.tgz" "$YOUKI_URL"

echo "==> Verifying sha256"
echo "${YOUKI_SHA256}  $tmp/youki.tgz" | sha256sum -c -

echo "==> Installing youki to ${DEST}"
tar xzf "$tmp/youki.tgz" -C "$tmp" youki
install -m 0755 "$tmp/youki" "$DEST"
"$DEST" --version
echo "==> youki installed at ${DEST}"
