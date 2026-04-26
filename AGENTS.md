# AGENTS.md

This file provides guidance to coding agents working in this repository.

This repo is a thin podman wrapper around upstream `southleft/figma-console-mcp`. It contains no application code — only a `Containerfile`, a `compose.yaml`, an `.env.example`, a Quadlet unit, and shell scripts under `scripts/`. Read `README.md` for the user-facing build/install/run flow and `SECURITY.md` for the threat model; this file captures rules that aren't obvious from the code.

## Architecture in one paragraph

Upstream `dist/local.js` is a stdio-only MCP server. To run it as a long-running, Quadlet-managed service like other enterprise MCP wrappers, the runtime image bundles `sparfenyuk/mcp-proxy` (Python). `mcp-proxy` listens on `0.0.0.0:8000` inside the container and spawns one `node /app/dist/local.js` child per MCP client session, bridging its stdio to streamable-http. The host publishes `127.0.0.1:23148:8000`, so the endpoint is loopback-only. The MCP client (OpenCode) connects to `http://127.0.0.1:23148/mcp` as a `type: "remote"` server. A native streamable-http transport is tracked upstream as [southleft/figma-console-mcp#48](https://github.com/southleft/figma-console-mcp/issues/48); when it lands, the `mcp-proxy` layer goes away.

## Hard constraints

- **Loopback-only network exposure.** Both `compose.yaml` and `systemd/figma-console-mcp.container` publish the port as `127.0.0.1:23148:8000`. The `127.0.0.1` prefix is **load-bearing** — it makes the endpoint host-only. Never drop it or change to `0.0.0.0`. If cross-host access is needed, front it with an authenticated reverse proxy on the host. Keep the host port (23148) consistent across both files. Container-internal bind stays `0.0.0.0:8000` (private network namespace).
- **Read-only by design.** The Figma PAT must be a least-privilege read-only token (see `.env.example`). Container also runs `read_only: true`, `cap_drop: ALL`, `no-new-privileges`, non-root `node` user. Do not relax these.
- **Resource caps live in the Quadlet `[Service]` section** (`MemoryMax`, `CPUQuota`, `TasksMax`) and the `[Container]` section (`PidsLimit`). These bound the whole container — mcp-proxy + every spawned node child combined. Compose mirrors them via `pids_limit` / `mem_limit` / `cpus`. Keep both in sync if you change one.
- **Runtime egress is to `api.figma.com` only.** No telemetry, no auto-update, no Cloud Mode (`*.southleft.com`), no Remote SSE. Only `dist/local.js` is executed by the children mcp-proxy spawns.
- **Corporate CAs come from the build host's anchor dir** (`/etc/pki/ca-trust/source/anchors/`) via `podman build -v ...:/host-anchors:ro,Z`. Imported in BOTH the builder and runtime stages. `NODE_EXTRA_CA_CERTS` and `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` point at the system bundle so Node *and* mcp-proxy/Python use it (Node does not read the system trust store by default). Do not commit any CA material; do not add a `certs/` directory; do not mount certs at runtime.
- **The PAT is a runtime secret.** It lives in `.env` (chmod 600), read by Quadlet's `EnvironmentFile=` and forwarded into spawned node children by `mcp-proxy --pass-environment`. Never bake it into the image, never put it in the OpenCode config (the move from "PAT in `~/.config/opencode/opencode.json`" to "PAT in `.env`" was deliberate — one rotation point, less leakage surface).

## Naming / tooling conventions

- Use `Containerfile`, never `Dockerfile`.
- Use `compose.yaml`, never `docker-compose.yml` / `.yml`. All YAML files use `.yaml`.
- Invoke `podman` and `podman-compose`. Don't introduce `docker` commands.
- The image is tagged `localhost/figma-console-mcp:local` *and* `localhost/figma-console-mcp:<VERSION>`. Keep both in sync when changing build logic.
- Shell scripts live under `scripts/` and `cd "$(dirname "$0")/.."` so they work from any CWD.

## Editing the Containerfile

- Build stage clones `southleft/figma-console-mcp` at the tag from `ARG VERSION` (default `latest`, resolved via the GitHub releases API).
- The CA-import `RUN --mount=type=bind,source=/host-anchors,...` block appears in BOTH stages. The runtime copy is load-bearing — without it, `NODE_EXTRA_CA_CERTS` points at a bundle missing the corp CAs and `api.figma.com` calls fail behind a TLS-intercepting proxy.
- The runtime image is intentionally Node 22 + Python 3 (for mcp-proxy in a venv at `/opt/mcp-proxy`). Don't switch to a single-language base; you'd lose either the upstream code or the bridge.
- Runtime user is `node` (uid 1000). Don't switch back to root.
- `mcp-proxy` is pinned via `ARG MCP_PROXY_VERSION`; bump it deliberately, not on every build.
- ENTRYPOINT runs `mcp-proxy --host 0.0.0.0 --port 8000 --pass-environment -- node /app/dist/local.js`. **Do not add `--stateless`** — without it, sessions are tracked and one node child serves a whole client session; with it, every HTTP request is independent and node spawns are unbounded.

## Updates

- Routine update = `./scripts/update.sh vX.Y.Z`. The script writes/updates `VERSION=` in `.env` (consumed by `scripts/build.sh`) and rebuilds. Tags use upstream's `vX.Y.Z` form — `git clone --branch` consumes that verbatim. Don't strip the leading `v`.
- After rebuild: `systemctl --user restart figma-console-mcp.service`.
- No auto-update mechanism by design. Image is rebuilt on the build host, never pulled at runtime.

## What not to add

- No `Dockerfile`, no `docker-compose.yml`.
- No `0.0.0.0` host publish, no host bind mounts (`-v` / `Volume=`).
- No CA files, no PAT, no `.env` checked in. `.env`/`.env.bak`/`*.local` are gitignored.
- No package.json or Node code in this repo — server code comes from the cloned upstream.
- No `podman auto-update` labels — the wrapper exists so the runtime never has to pull.
