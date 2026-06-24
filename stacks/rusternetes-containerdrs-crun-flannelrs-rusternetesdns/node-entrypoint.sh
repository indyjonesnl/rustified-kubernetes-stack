#!/bin/sh
# Entrypoint for a rusternetes node whose runtime is containerd-rs + crun (NOT
# the stock containerd + Youki). One container runs containerd-rs (CRI) AND the
# kubelet, kind-style, so the kubelet's hostPath validation and the runtime's
# hostPath mounts share one filesystem — required for flannel-rs's CNI install
# (/opt/cni/bin, /etc/cni/net.d, /run/flannel) and for pod hostPath volumes.
#
# Adapted from the branch's deploy/node/entrypoint.sh. The one substantive
# change: the stock entrypoint launches `/usr/local/bin/containerd --config
# /etc/containerd/config.toml` (stock-containerd's config schema). Our runtime is
# containerd-rs, which parses its OWN config schema, so we launch it explicitly
# against /etc/containerd-rs/config.toml rather than relying on a binary/config
# symlink dance. Everything else (cgroup-v2 nesting fix, socket wait, exec
# kubelet in the foreground) is kept verbatim from the branch.
set -e

# --- containerd-rs prerequisites ----------------------------------------------
sysctl -w fs.inotify.max_user_instances=1024 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null 2>&1 || true

# cgroup v2 nesting fix (kind/k3d): move our processes into a leaf so controllers
# can be delegated, else crun fails with "+io ... Not supported".
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    mkdir -p /sys/fs/cgroup/init
    while read -r pid; do
        echo "$pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    done < /sys/fs/cgroup/cgroup.procs
    for c in $(cat /sys/fs/cgroup/cgroup.controllers); do
        echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    done
fi

# flannel-rs's DaemonSet installs the CNI plugins + conflist into these dirs at
# runtime, so make sure they exist + are writable before the kubelet/containerd-rs
# start. (Dockerfile.node-rs also mkdir's them; belt-and-braces for fresh volumes.)
mkdir -p /opt/cni/bin /etc/cni/net.d /run/flannel /run/containerd

# --- start containerd-rs in the background ------------------------------------
/usr/local/bin/containerd-rs --config /etc/containerd-rs/config.toml &
CONTAINERD_PID=$!

# Wait for the CRI socket before launching the kubelet.
for _ in $(seq 1 50); do
    [ -S /run/containerd/containerd.sock ] && break
    sleep 0.2
done

# If containerd-rs died, surface it.
if ! kill -0 "$CONTAINERD_PID" 2>/dev/null; then
    echo "containerd-rs failed to start" >&2
    exit 1
fi

# --- run the kubelet in the foreground ----------------------------------------
# CONTAINER_RUNTIME_ENDPOINT defaults to the local socket; the kubelet talks to
# this node's own containerd-rs.
exec /usr/local/bin/kubelet "$@"
