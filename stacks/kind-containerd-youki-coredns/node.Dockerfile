# syntax=docker/dockerfile:1

# kind node whose OCI runtime is Youki (the Rust runtime), driven by containerd's
# STOCK Go runc-v2 shim via the runc option BinaryName -> youki.
#
# We deliberately do NOT use the Rust shim (containerd-shim-runc-v2-rs): it boots
# and passes the smoke test, but cannot keep the control plane alive under
# sig-network [Conformance] churn (it drops container lifecycle events, the kubelet's
# CRI cache desyncs, and every static pod enters a restart spiral). The mature Go
# shim runs youki rock-solid -- 52/52 sig-network [Conformance], 0 failures.
# Bonus: the Go shim deserializes the runc options proto correctly, so BinaryName
# works and we need no runc->youki symlink hack.

# ---- Fetch Youki (pinned, verified prebuilt release binary -- no compile) ----
FROM debian:bookworm-slim AS youki-fetch
ARG YOUKI_VERSION=0.6.0
ARG YOUKI_SHA256=e920231ee35a157d48e267611a00c9d5f75b60b003818aa571dda04ca9196e59
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/youki.tar.gz \
      "https://github.com/youki-dev/youki/releases/download/v${YOUKI_VERSION}/youki-${YOUKI_VERSION}-x86_64-gnu.tar.gz" \
    && echo "${YOUKI_SHA256}  /tmp/youki.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/youki.tar.gz -C /usr/local/bin youki \
    && /usr/local/bin/youki --version

# ---- Final kind node image ----
FROM kindest/node:v1.35.0
COPY --from=youki-fetch /usr/local/bin/youki /usr/local/bin/youki
RUN chmod +x /usr/local/bin/youki && /usr/local/bin/youki --version
