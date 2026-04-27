FROM node:22-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

# Bake corporate CAs into the build stage so npm/git over HTTPS work behind a
# TLS-intercepting proxy. Mount provided by scripts/build.sh via a named build
# context — works with both podman and docker BuildKit:
#   podman/docker build --build-context hostcerts=/etc/pki/ca-trust/source/anchors ...
RUN --mount=type=bind,from=hostcerts,target=/host-anchors,ro \
    for f in /host-anchors/*; do \
        [ -f "$f" ] || continue; \
        base=$(basename "$f"); \
        cp "$f" "/usr/local/share/ca-certificates/${base%.*}.crt"; \
    done && \
    update-ca-certificates

# NPM_REGISTRY must be passed in by the caller (scripts/build.sh, the CI
# workflow, or `.env`). No default here on purpose — having a "fallback"
# meant two places knew the default and the .env override felt cosmetic.
ARG NPM_REGISTRY
RUN test -n "$NPM_REGISTRY" || { echo "Error: NPM_REGISTRY build-arg is required" >&2; exit 1; } && \
    npm config set registry "$NPM_REGISTRY" && \
    npm ping || { echo "Error: Cannot reach npm registry at ${NPM_REGISTRY}" >&2; exit 1; }

ARG VERSION=latest

WORKDIR /src
RUN set -eux; \
    if [ "$VERSION" = "latest" ]; then \
      VERSION=$(curl -fsSL https://api.github.com/repos/southleft/figma-console-mcp/releases/latest \
                | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//'); \
    fi; \
    git clone --depth 1 --branch "$VERSION" https://github.com/southleft/figma-console-mcp.git .

# Disable Figma Desktop Bridge wiring. The bridge requires a running Figma
# Desktop reachable at localhost:9222 (CDP) or via a WebSocket plugin — neither
# is available in this headless container, so every tool call attempted the
# bridge first, failed, and fell back to REST. We strip the bridge entry points
# so it goes straight to REST without the noise. Patterns are stable across
# upstream releases at the v1.20.x line; the build will fail loudly if they
# disappear (counts asserted below).
RUN set -eux; \
    test "$(grep -c '() => this\.getDesktopConnector()' src/local.ts)" -ge 1; \
    test "$(grep -c '() => this\.browserManager || null' src/local.ts)" -ge 1; \
    test "$(grep -c 'this\.autoConnectToFigma();' src/local.ts)" -ge 1; \
    test "$(grep -c 'private async ensureInitialized(): Promise<void> {' src/local.ts)" -eq 1; \
    test "$(grep -c 'private async getDesktopConnector(): Promise<IFigmaConnector> {' src/local.ts)" -eq 1; \
    sed -i 's|() => this\.getDesktopConnector()|(null as any)|g' src/local.ts; \
    sed -i 's|() => this\.browserManager \|\| null|(null as any)|g' src/local.ts; \
    sed -i 's|this\.autoConnectToFigma();|/* bridge disabled */|g' src/local.ts; \
    sed -i 's|private async ensureInitialized(): Promise<void> {|private async ensureInitialized(): Promise<void> { throw new Error("Desktop Bridge disabled in this build");|' src/local.ts; \
    sed -i 's|private async getDesktopConnector(): Promise<IFigmaConnector> {|private async getDesktopConnector(): Promise<IFigmaConnector> { throw new Error("Desktop Bridge disabled in this build");|' src/local.ts

# Only the local stdio target — `npm run build` also tries the Cloudflare
# Worker and Vite app targets, which we don't ship and which have upstream TS
# errors we shouldn't try to fix from a wrapper repo.
#
# `--mount=type=cache,target=/root/.npm` lets BuildKit reuse the npm package
# cache across builds (and, with cache-to=gha mode=max in CI, across runs).
# `--prefer-offline` consults the cache before the registry; with a warm
# cache `npm ci` becomes CPU-bound instead of download-bound.
RUN --mount=type=cache,target=/root/.npm,sharing=locked,id=npm-cache \
    npm ci --prefer-offline && npm run build:local && npm prune --omit=dev

# --- runtime stage ---
# Node + Python 3 in one image. Node runs the upstream stdio MCP server
# (dist/local.js), Python runs sparfenyuk/mcp-proxy which spawns it as a child
# and exposes JSON-RPC as streamable-http on 0.0.0.0:8000.
#
# Why bridge instead of stdio: upstream issue #48 tracks a native
# streamable-http transport. Until that lands, this proxy lets us run the
# server as a long-running, Quadlet-managed service like other enterprise
# MCP wrappers.
FROM node:22-slim

ARG MCP_PROXY_VERSION=0.11.0

# OCI image metadata. VERSION mirrors the build-stage ARG so a published image
# carries the upstream tag it was built from. GIT_SHA / IMAGE_SOURCE come from
# CI (see .github/workflows/build.yaml) and default to placeholders for local
# builds — `unknown` is fine for dev images and clearly signals "not from CI".
ARG VERSION=latest
ARG GIT_SHA=unknown
ARG IMAGE_SOURCE=https://github.com/trick77/mcp-figma-podman

LABEL org.opencontainers.image.title="figma-console-mcp" \
      org.opencontainers.image.description="Hardened podman wrapper around southleft/figma-console-mcp (read-only Figma MCP over streamable-http)" \
      org.opencontainers.image.source="$IMAGE_SOURCE" \
      org.opencontainers.image.revision="$GIT_SHA" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Re-import host CAs in the runtime stage too. Node does NOT read the system
# trust store by default; NODE_EXTRA_CA_CERTS below points at this bundle so
# api.figma.com calls validate behind a TLS-intercepting proxy. mcp-proxy is
# Python and uses the system bundle directly via REQUESTS_CA_BUNDLE.
RUN --mount=type=bind,from=hostcerts,target=/host-anchors,ro \
    for f in /host-anchors/*; do \
        [ -f "$f" ] || continue; \
        base=$(basename "$f"); \
        cp "$f" "/usr/local/share/ca-certificates/${base%.*}.crt"; \
    done && \
    update-ca-certificates

# Install mcp-proxy into a venv owned by root, on PATH for everyone.
RUN python3 -m venv /opt/mcp-proxy && \
    /opt/mcp-proxy/bin/pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}" && \
    ln -s /opt/mcp-proxy/bin/mcp-proxy /usr/local/bin/mcp-proxy

WORKDIR /app
COPY --from=builder --chown=node:node /src/dist                 /app/dist
COPY --from=builder --chown=node:node /src/node_modules         /app/node_modules
COPY --from=builder --chown=node:node /src/package.json         /app/package.json

USER node
ENV NODE_ENV=production \
    HOME=/home/node \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 8000

# TCP-only readiness probe: confirms mcp-proxy is listening on :8000.
# Deliberately NOT a JSON-RPC `initialize` — that creates a session and spawns
# a node child per healthcheck (mcp-proxy tracks sessions), wasting PIDs and
# polluting logs. A wedged proxy that has stopped accepting TCP connections
# is the failure mode worth catching here; deeper bridge wedges are rare and
# would still surface to the MCP client as a stalled request.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1',8000))" || exit 1

# mcp-proxy spawns one `node /app/dist/local.js` child per MCP client session
# (NOT per request — sessions are tracked, so OpenCode + Cursor + Claude Code
# concurrently = 3 long-lived node processes, not N-per-tool-call).
# Hard ceilings on memory/CPU/PIDs come from the Quadlet [Container] section
# (MemoryMax/CPUQuota/PIDsLimit), see systemd/figma-console-mcp.container.
# --pass-environment forwards FIGMA_ACCESS_TOKEN (and other env) into children.
ENTRYPOINT ["mcp-proxy", "--host", "0.0.0.0", "--port", "8000", \
            "--pass-environment", "--", \
            "node", "/app/dist/local.js"]
