# syntax=docker/dockerfile:1

# kind node whose OCI runtime is crun (the fast C runtime), driven by containerd's
# stock Go runc-v2 shim via the runc option BinaryName -> crun. Sibling of the
# kind-containerd-youki-coredns stack -- identical wiring, only the OCI runtime
# binary differs (crun vs youki), for a clean runtime-to-runtime comparison.

# ---- Fetch crun (pinned, verified prebuilt static release binary -- no compile) ----
FROM debian:bookworm-slim AS crun-fetch
ARG CRUN_VERSION=1.28
ARG CRUN_SHA256=2aa6b7024a9c9f153895c0d11ae233d3758f54844011c3a039e3e89048d01d42
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /usr/local/bin/crun \
      "https://github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-amd64" \
    && echo "${CRUN_SHA256}  /usr/local/bin/crun" | sha256sum -c - \
    && chmod +x /usr/local/bin/crun \
    && /usr/local/bin/crun --version

# ---- Final kind node image ----
FROM kindest/node:v1.35.0
COPY --from=crun-fetch /usr/local/bin/crun /usr/local/bin/crun
RUN chmod +x /usr/local/bin/crun && /usr/local/bin/crun --version
