#!/usr/bin/env bash
set -eu
mkdir -p /run/containerd /var/lib/containerd-rs /run/containerd-rs /etc/cni/net.d /opt/cni/bin
exec containerd-rs --config /etc/containerd-rs/config.toml
