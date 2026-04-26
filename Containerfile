FROM node:20-slim AS builder

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

ARG NPM_REGISTRY=https://registry.npmjs.org/
RUN npm config set registry "$NPM_REGISTRY" && \
    npm ping || { echo "Error: Cannot reach npm registry at ${NPM_REGISTRY}" >&2; exit 1; }

ARG VERSION=latest

WORKDIR /src
RUN set -eux; \
    if [ "$VERSION" = "latest" ]; then \
      VERSION=$(curl -fsSL https://api.github.com/repos/southleft/figma-console-mcp/releases/latest \
                | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//'); \
    fi; \
    git clone --depth 1 --branch "$VERSION" https://github.com/southleft/figma-console-mcp.git .

# Only the local stdio target — `npm run build` also tries the Cloudflare
# Worker and Vite app targets, which we don't ship and which have upstream TS
# errors we shouldn't try to fix from a wrapper repo.
RUN npm ci && npm run build:local && npm prune --omit=dev

# --- runtime stage ---
# Node + Python 3 in one image. Node runs the upstream stdio MCP server
# (dist/local.js), Python runs sparfenyuk/mcp-proxy which spawns it as a child
# and exposes JSON-RPC as streamable-http on 0.0.0.0:8000.
#
# Why bridge instead of stdio: upstream issue #48 tracks a native
# streamable-http transport. Until that lands, this proxy lets us run the
# server as a long-running, Quadlet-managed service like other enterprise
# MCP wrappers.
FROM node:20-slim

ARG MCP_PROXY_VERSION=0.10.0

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
COPY --from=builder --chown=node:node /src/figma-desktop-bridge /app/figma-desktop-bridge

USER node
ENV NODE_ENV=production \
    HOME=/home/node \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 8000

# mcp-proxy spawns one `node /app/dist/local.js` child per MCP client session
# (NOT per request — sessions are tracked, so OpenCode + Cursor + Claude Code
# concurrently = 3 long-lived node processes, not N-per-tool-call).
# Hard ceilings on memory/CPU/PIDs come from the Quadlet [Container] section
# (MemoryMax/CPUQuota/PIDsLimit), see systemd/figma-console-mcp.container.
# --pass-environment forwards FIGMA_ACCESS_TOKEN (and other env) into children.
ENTRYPOINT ["mcp-proxy", "--host", "0.0.0.0", "--port", "8000", \
            "--pass-environment", "--", \
            "node", "/app/dist/local.js"]
