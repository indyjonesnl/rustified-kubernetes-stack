# podman-youki Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Podman runs containers **and pods** on the Youki OCI runtime (rootful), with a smoke test exercising run/env/volume/exec/logs/pod, gated by GitHub Actions with a status badge.

**Architecture:** No Kubernetes, no kind — host-level Podman. `setup.sh` installs a pinned, sha256-verified youki v0.6.0 release binary to `/usr/local/bin/youki` and checks podman is present. The smoke test runs `sudo podman --runtime /usr/local/bin/youki ...` (rootful; explicit `--runtime` flag, no global config mutation) and asserts behavior, including a 2-container pod sharing localhost and a runtime==youki check. A Makefile is the entrypoint; a GitHub Actions workflow runs it on a clean runner.

**Tech Stack:** Podman (rootful), Youki v0.6.0 (pinned release binary), bash, GitHub Actions, ubuntu-latest.

**Verification reality:** rootful podman needs passwordless sudo + podman, which the dev host lacks. Per-task "tests" here are **offline** (bash syntax, yaml parse). The authoritative end-to-end gate is **CI** (`make -C stacks/podman-youki all` on ubuntu-latest). This mirrors the kind-containerd-youki-coredns stack.

**Pinned artifact:**
- URL: `https://github.com/youki-dev/youki/releases/download/v0.6.0/youki-0.6.0-x86_64-gnu.tar.gz`
- SHA256: `e920231ee35a157d48e267611a00c9d5f75b60b003818aa571dda04ca9196e59`
- Tarball top-level layout: `youki` (binary), `README.md`, `LICENSE`.

---

## File Structure

```
stacks/podman-youki/
  setup.sh           # download+verify pinned youki; install to /usr/local/bin; check podman
  smoke/
    smoke-test.sh    # rootful podman+youki: run/env/volume, exec, logs, pod, runtime==youki
  Makefile           # setup / smoke / clean / all
.github/workflows/podman-youki.yml
README.md            # add a CI badge row
```

---

## Task 1: setup.sh — install pinned youki + check podman

**Files:**
- Create: `stacks/podman-youki/setup.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Syntax check (offline; install/run needs root+podman, done in CI)**

Run: `bash -n stacks/podman-youki/setup.sh && echo "syntax ok"`
Expected: `syntax ok`. (Do not run the script here — it writes to `/usr/local/bin` and needs podman; CI exercises it.)

- [ ] **Step 3: Commit**

```bash
git add stacks/podman-youki/setup.sh
git commit -m "feat(podman-youki): setup script installing pinned youki v0.6.0"
```
End the commit body (after a blank line) with:
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 2: smoke/smoke-test.sh — rootful podman+youki smoke test

**Files:**
- Create: `stacks/podman-youki/smoke/smoke-test.sh`

Runs as root (invoked via `sudo` from the Makefile), so `podman` here is rootful. Uses fully-qualified image names to avoid podman's interactive short-name registry prompt (which would hang CI).

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Syntax check (offline)**

Run: `bash -n stacks/podman-youki/smoke/smoke-test.sh && echo "syntax ok"`
Expected: `syntax ok`.

- [ ] **Step 3: Make executable + commit**

```bash
chmod +x stacks/podman-youki/smoke/smoke-test.sh
git add stacks/podman-youki/smoke/smoke-test.sh
git commit -m "feat(podman-youki): rootful podman+youki smoke test (run/exec/logs/pod)"
```
End the commit body with the Co-Authored-By trailer.

---

## Task 3: Makefile

**Files:**
- Create: `stacks/podman-youki/Makefile`

- [ ] **Step 1: Write the Makefile (TAB-indented recipes)**

```makefile
DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SUDO ?= sudo

.PHONY: setup smoke clean all

setup:
	$(SUDO) bash $(DIR)setup.sh

smoke:
	$(SUDO) YOUKI=/usr/local/bin/youki bash $(DIR)smoke/smoke-test.sh

clean:
	$(SUDO) podman pod rm -f py-smoke 2>/dev/null || true
	$(SUDO) podman rm -f py-exec py-logs py-rt 2>/dev/null || true

all: setup smoke
```

- [ ] **Step 2: Verify make parses the targets (offline)**

Run: `make -C stacks/podman-youki --dry-run all`
Expected: prints the `sudo bash .../setup.sh` and `sudo ... smoke-test.sh` commands without executing them. If "missing separator" appears, a recipe line used spaces — fix to a TAB.

- [ ] **Step 3: Commit**

```bash
git add stacks/podman-youki/Makefile
git commit -m "feat(podman-youki): Makefile entrypoint (setup/smoke/clean/all)"
```
End the commit body with the Co-Authored-By trailer.

---

## Task 4: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/podman-youki.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: podman-youki

on:
  push:
    branches: [main]
    paths:
      - 'stacks/podman-youki/**'
      - '.github/workflows/podman-youki.yml'
  pull_request:
    paths:
      - 'stacks/podman-youki/**'
      - '.github/workflows/podman-youki.yml'
  workflow_dispatch:

jobs:
  smoke:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - name: Ensure podman is installed
        run: |
          podman --version || (sudo apt-get update && sudo apt-get install -y podman)
          podman --version

      - name: Install youki + run podman smoke test
        run: make -C stacks/podman-youki all
```

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/podman-youki.yml')); print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/podman-youki.yml
git commit -m "ci(podman-youki): smoke workflow"
```
End the commit body with the Co-Authored-By trailer.

---

## Task 5: README badge row

**Files:**
- Modify: `README.md` (add a row to the existing "Stack CI status" table)

- [ ] **Step 1: Read the current table**

Run: `sed -n '/Stack CI status/,/regressed/p' README.md`
Confirm there is a markdown table with a header row and the `kind-containerd-youki-coredns` row.

- [ ] **Step 2: Add the podman-youki row**

Insert this row immediately after the `kind-containerd-youki-coredns` table row (keep alignment with the existing columns):

```markdown
| `podman-youki` | ![podman-youki](https://github.com/indyjonesnl/rustified-kubernetes-stack/actions/workflows/podman-youki.yml/badge.svg) |
```

- [ ] **Step 3: (optional) add a short section**

If the README has a per-stack section for `kind-containerd-youki-coredns`, add a brief `## podman-youki` section after it:

```markdown
## podman-youki

Host-level Podman (rootful) running containers and pods on the **Youki** OCI runtime
(pinned v0.6.0) — the runtime foundation for the Rusternetes (Path B) north star.

Requirements: `podman`, `make`, `sudo` (rootful). youki is installed by `setup.sh`.

```bash
make -C stacks/podman-youki all      # install youki + run the smoke test
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(podman-youki): add CI badge + quickstart"
```
End the commit body with the Co-Authored-By trailer.

---

## Self-Review notes (for the implementer)

- **Spec coverage:** setup (pinned+verified youki + podman check), smoke (run/env/volume/exec/logs/pod/runtime-proof), Makefile entrypoint, CI workflow, README badge — all covered.
- **No local run:** the dev host lacks passwordless sudo + podman, so per-task tests are offline only (`bash -n`, `make --dry-run`, yaml parse). CI is the authoritative gate. Do NOT attempt `sudo` locally.
- **Fully-qualified images** (`docker.io/library/...`) are required so rootful podman doesn't hang on the interactive short-name registry prompt.
- **Naming consistency:** dir `stacks/podman-youki/`, workflow `podman-youki.yml`, badge path matches the workflow filename, container/pod names (`py-*`) are consistent between smoke-test.sh and the Makefile `clean` target.
```
