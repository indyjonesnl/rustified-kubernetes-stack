#!/usr/bin/env bash
set -euo pipefail

YOUKI="${YOUKI:-/usr/local/bin/youki}"
RT=(--runtime "$YOUKI")
IMG_ALPINE="docker.io/library/alpine:3.20"
IMG_NGINX="docker.io/library/nginx:1.27-alpine"
POD="py-smoke"
EXEC_CTR="py-exec"
LOG_CTR="py-logs"
RT_CTR="py-rt"
WORK="$(mktemp -d)"

cleanup() {
  podman rm -f "$EXEC_CTR" "$LOG_CTR" "$RT_CTR" >/dev/null 2>&1 || true
  podman pod rm -f "$POD" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> youki version"
"$YOUKI" --version

echo "==> run: env var + bind-mount volume"
out=$(podman "${RT[@]}" run --rm -e FOO=bar -v "$WORK:/data:Z" "$IMG_ALPINE" \
        sh -c 'echo "$FOO" > /data/out && cat /data/out')
[ "$out" = "bar" ] || { echo "FAIL: env/volume run produced: '$out'"; exit 1; }
test -f "$WORK/out" || { echo "FAIL: volume not written back to host"; exit 1; }
echo "    ok ($out, host file present)"

echo "==> exec into a running container (youki exec path)"
podman "${RT[@]}" run -d --name "$EXEC_CTR" "$IMG_ALPINE" sleep 300 >/dev/null
podman exec "$EXEC_CTR" sh -c 'echo execworks' | grep -q execworks \
  || { echo "FAIL: exec did not return expected output"; exit 1; }
echo "    ok"

echo "==> logs"
podman "${RT[@]}" run --name "$LOG_CTR" "$IMG_ALPINE" sh -c 'echo hello-logs' >/dev/null
podman logs "$LOG_CTR" | grep -q hello-logs || { echo "FAIL: podman logs missing output"; exit 1; }
echo "    ok"

echo "==> pod: two containers sharing localhost"
podman "${RT[@]}" pod create --name "$POD" >/dev/null
podman "${RT[@]}" run -d --pod "$POD" --name "${POD}-web" "$IMG_NGINX" >/dev/null
resp=""
for i in $(seq 1 15); do
  resp=$(podman "${RT[@]}" run --rm --pod "$POD" "$IMG_ALPINE" \
           sh -c 'wget -qO- http://127.0.0.1:80 2>/dev/null' || true)
  echo "$resp" | grep -qi "nginx\|welcome" && break
  sleep 2
done
echo "$resp" | grep -qi "nginx\|welcome" \
  || { echo "FAIL: in-pod client could not reach nginx on 127.0.0.1"; exit 1; }
echo "    ok (shared netns http reachable)"

echo "==> verify runtime == youki"
podman "${RT[@]}" run -d --name "$RT_CTR" "$IMG_ALPINE" sleep 60 >/dev/null
ocirt=$(podman inspect "$RT_CTR" --format '{{.OCIRuntime}}')
echo "    OCIRuntime=$ocirt"
echo "$ocirt" | grep -qi youki || { echo "FAIL: OCIRuntime is not youki: $ocirt"; exit 1; }
state=$(podman inspect "$RT_CTR" --format '{{.State.Status}}')
[ "$state" = "running" ] || { echo "FAIL: youki-run container not running (state=$state)"; exit 1; }
echo "    ok (running on youki)"

echo "PASS: podman-youki smoke test"
