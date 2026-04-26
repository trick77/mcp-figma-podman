# figma-console-mcp (podman, read-only, streamable-http)

> **Built for enterprise / regulated workstations.** This repo targets the kind of environment you find inside large corporates and government tenants: build hosts behind a TLS-intercepting proxy with corporate root CAs in `/etc/pki/ca-trust/source/anchors/`, rootless podman, systemd-managed services that survive a reboot, and a strong preference for "the AI agent should not be able to read my home directory."
>
> If you're on a personal laptop with no corporate proxy and you trust the upstream Node process to run loose on your machine, you don't need this repo — `npx figma-console-mcp@latest` works fine on its own.
>
> **What this repo is.** A thin packaging layer that wraps the OSS project [`southleft/figma-console-mcp`](https://github.com/southleft/figma-console-mcp) (community-maintained, third-party — not affiliated with Figma) and ships it as a hardened, long-running podman container suitable for an enterprise workstation. All Figma tools, auth, and protocol handling come from upstream. For server features or bugs, file issues there. For packaging questions (build, install, hardening, network policy), see this README.
>
> **Why wrap it.** Three reasons:
>
> 1. **Enterprise build environment.** Upstream is published to npm; pulling it on a corporate-proxied build host means HTTPS to the npm registry and to GitHub goes through a TLS-intercepting proxy. The Containerfile bakes the corporate root CAs from `/etc/pki/ca-trust/source/anchors/` into BOTH the build stage (so `npm ci` / `git clone` succeed) and the runtime stage (so Node's `NODE_EXTRA_CA_CERTS` and Python's `REQUESTS_CA_BUNDLE` actually trust `api.figma.com` when *that* call is intercepted too). Node does not read the system trust store by default — without the runtime import you get `UNABLE_TO_VERIFY_LEAF_SIGNATURE` in production.
> 2. **Reduced blast radius for the running process.** When an MCP client launches the upstream tool directly via `npx`, it inherits your full user environment: read access to `$HOME`, your SSH keys, your shell history, every browser profile, every other token on disk. This wrapper instead launches the server as a non-root user inside a `--read-only` container with `--cap-drop=ALL`, `--security-opt=no-new-privileges`, no host bind mounts, and only a loopback-bound port. The server can talk to `api.figma.com` with your PAT and that is all it can do. Even a fully compromised upstream release cannot read your `~/.aws/credentials` or rm-rf your repo.
> 3. **Long-running, systemd-managed lifecycle.** The container is a Quadlet unit that starts at boot and stays up across MCP client restarts. The PAT lives in `.env` (one rotation point, chmod 600) instead of being copy-pasted into every MCP client's config file.
>
> **About the bridge.** Upstream `dist/local.js` only speaks **stdio**. To run it as a long-running service we bundle [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) inside the same container; mcp-proxy listens on `:8000` and spawns one `node /app/dist/local.js` child per MCP client session, bridging its stdio to streamable-http. A native streamable-http transport is tracked upstream as [southleft/figma-console-mcp#48](https://github.com/southleft/figma-console-mcp/issues/48); when it lands, the bridge layer goes away.

See [SECURITY.md](./SECURITY.md) (Swiss German) for a plain-language threat-model walkthrough.

## Prerequisites

- `podman` ≥ 4.4 (RHEL 9.3+ is fine)
- `podman-compose` ≥ 1.0.6 (only if you want to run via compose; Quadlet doesn't need it)
- A build host with corporate root CA(s) in `/etc/pki/ca-trust/source/anchors/`
  (override with `HOST_ANCHORS=/path/to/anchors`; the dir may be empty on a
  non-corporate host).
- A **read-only** Figma personal access token. Create at
  https://www.figma.com/developers/api#access-tokens and grant ONLY:
  - File content: **Read-only**
  - Variables: **Read-only**
  - (optionally) Dev resources, Library content: Read-only

  Do **not** grant any "Write" scopes.

## First-time setup

```sh
cp .env.example .env
$EDITOR .env                       # set FIGMA_ACCESS_TOKEN, optionally pin VERSION
./scripts/build.sh
./scripts/install-systemd.sh       # rootless Quadlet, starts service at boot
./scripts/install-opencode.sh      # writes the OpenCode MCP entry
```

Then restart OpenCode. The MCP server appears as `figma-console-mcp` and points at `http://127.0.0.1:23148/mcp`.

Manage afterwards:

```sh
systemctl --user status   figma-console-mcp.service
systemctl --user restart  figma-console-mcp.service
journalctl --user -u figma-console-mcp.service -f
```

## How it works (1-minute version)

1. Quadlet boots `localhost/figma-console-mcp:local` and publishes `127.0.0.1:23148:8000`.
2. Inside the container, `mcp-proxy` listens on `:8000`.
3. OpenCode reads `~/.config/opencode/opencode.json`, sees the remote MCP entry, opens a streamable-http connection to `http://127.0.0.1:23148/mcp`, sends `initialize` → `tools/list`.
4. mcp-proxy spawns `node /app/dist/local.js` for that session, with `FIGMA_ACCESS_TOKEN` already in env (forwarded from `.env` via `--pass-environment`). The child enumerates tools and serves `tools/call`s for the rest of the session.
5. When OpenCode disconnects, the child exits. The container stays up.

One MCP client session = one persistent node child. Three concurrent clients = three children. Hard ceilings (`MemoryMax=512M`, `CPUQuota=100%`, `PidsLimit=64`) are set in the Quadlet unit.

## Updates

```sh
./scripts/update.sh v1.22.3       # any tag from southleft/figma-console-mcp releases
systemctl --user restart figma-console-mcp.service
```

`update.sh` writes `VERSION=v1.22.3` into `.env`, rebuilds the image with fresh corporate CAs, and prunes dangling layers. `podman auto-update` is **intentionally not used** — the image is built on a controlled host, never pulled at runtime.

## What works

Read-only Figma API tools:

- `figma_get_variables`, `figma_get_styles`
- `figma_get_component`, `figma_get_component_set`, `figma_get_component_usages`
- `figma_get_file_data`, `figma_get_file_for_plugin`
- `figma_get_design_system_kit`
- `figma_check_design_parity`, `figma_generate_component_doc`
- `figma_get_status`

## What does NOT work (by design)

- All write operations (creating frames, editing variables, posting comments, etc.)
- FigJam / Slides creation
- Desktop Bridge tools: console logs, screenshots, `figma_execute`

Writes are blocked twice over:

1. **No transport.** The Desktop Bridge plugin is never installed and the container has no path to a Figma Desktop instance. Any tool that relies on the bridge fails immediately.
2. **Least-privilege PAT.** Even if something tried to hit Figma's REST API with a write call, Figma rejects it server-side because the token has no write scopes.

## No third-party endpoints

At runtime the container talks to **one** external host:

- `api.figma.com` — Figma's own REST API, using your PAT, against your own
  Figma account.

Cloud Mode and Remote SSE (which use `*.southleft.com`) are upstream features
we deliberately do not build or invoke — only `dist/local.js` is executed.
There is no telemetry, no auto-update, no OAuth proxy. See
[SECURITY.md](./SECURITY.md) for the threat model.

## Network posture

**Host-only exposure.** Both `compose.yaml` and the Quadlet unit publish the port as `127.0.0.1:23148:8000`. Podman's port forwarder binds only on the loopback interface, so the MCP endpoint is reachable from the host itself but not from any other machine. The container's internal `0.0.0.0:8000` bind is the *container's* network namespace — that's not the host interface.

Verify after start:

```sh
ss -ltn 'sport = :23148'                          # only 127.0.0.1:23148 (and/or [::1]:23148)
curl -i http://127.0.0.1:23148/mcp                # works from the host
curl -i http://<host-external-ip>:23148/mcp       # MUST fail / connection refused
```

If you ever need cross-host access, do not change the bind to `0.0.0.0` — front it with an authenticated reverse proxy on the host that listens externally and forwards to `127.0.0.1:23148`.

## Verification

```sh
# 1. Image built with corp CAs (count certs in the runtime bundle).
podman run --rm --entrypoint sh localhost/figma-console-mcp:local -c \
  'awk "/-----BEGIN CERTIFICATE-----/{c++} END{print c\" certs in bundle\"}" /etc/ssl/certs/ca-certificates.crt'

# 2. Service is up.
systemctl --user is-active figma-console-mcp.service

# 3. Tool list comes back over HTTP.
curl -sN -X POST http://127.0.0.1:23148/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head

# 4. api.figma.com TLS validates with the baked-in bundle.
podman exec figma-console-mcp node -e \
  "require('https').get('https://api.figma.com/v1/me', { headers: { 'X-Figma-Token': process.env.FIGMA_ACCESS_TOKEN }}, r => console.log('HTTP', r.statusCode)).on('error', e => { console.error(e.message); process.exit(1); })"
# expect: HTTP 200 (auth succeeded). 401/403 means PAT is bad. cert error = CA chain not validated.
```

## Hardening (applied by Quadlet / compose)

- `read-only` rootfs. Two throwaway tmpfs mounts (`/tmp`, `/home/node/.figma-console-mcp`) discarded on container exit.
- `cap_drop: ALL`, `no-new-privileges`. Runs as non-root `node` user.
- No host bind mounts. The server cannot read your `$HOME`, SSH keys, or any other on-disk credentials.
- Resource ceilings: `MemoryMax=512M`, `CPUQuota=100%`, `PidsLimit=64`. mcp-proxy + every spawned node child combined cannot exceed these.
- Loopback-only port publish.

## File permissions note

`.env` contains your PAT. `install-systemd.sh` sets it to mode `600`. `.env` is gitignored. Don't commit it.

## Layout

```
.
├── Containerfile                 # multi-stage Node + Python 3 + mcp-proxy
├── compose.yaml                  # podman-compose service definition
├── .env.example                  # config template (.env is gitignored)
├── scripts/
│   ├── build.sh                  # podman build with -v mount of host anchors
│   ├── update.sh                 # pin a new upstream tag, rebuild
│   ├── install-systemd.sh        # rootless Quadlet install for boot auto-start
│   └── install-opencode.sh       # write the OpenCode MCP "remote" entry
├── systemd/
│   └── figma-console-mcp.container  # Quadlet unit (templated)
├── README.md
├── SECURITY.md                   # threat model (Swiss German)
└── AGENTS.md                     # rules for coding agents working on this repo
```

## Uninstall

```sh
systemctl --user disable --now figma-console-mcp.service
rm ~/.config/containers/systemd/figma-console-mcp.container
systemctl --user daemon-reload
podman rmi localhost/figma-console-mcp:local
# Remove "figma-console-mcp" from .mcp in ~/.config/opencode/opencode.json
```
