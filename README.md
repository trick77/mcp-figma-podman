# figma-console-mcp (podman, read-only, streamable-http)

Hardened podman wrapper around [`southleft/figma-console-mcp`](https://github.com/southleft/figma-console-mcp). Built for enterprise workstations: corporate CAs baked in at build time, container is `--read-only` with no host access, PAT lives in `.env` (chmod 600), exposed only on `127.0.0.1:23148`.

Upstream speaks stdio only; we bundle [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) to expose streamable-http so the container can run as a long-lived Quadlet service. Native streamable-http transport tracked upstream in [#48](https://github.com/southleft/figma-console-mcp/issues/48).

## Using it (once installed)

You don't call any tool by name — OpenCode (or any MCP client) auto-discovers them on connect via `tools/list` and routes the agent there when your prompt mentions Figma. Concretely: just give the agent a Figma URL and say what you want.

Useful prompt shape:

1. **The file** — paste a Figma URL (`https://www.figma.com/file/<KEY>/<NAME>` or `https://www.figma.com/design/<KEY>/<NAME>`).
2. **What to extract** — variables, styles, components, file structure, design-system parity, etc.
3. **What to do with it** — summarize, generate a token JSON, compare to a code path, draft a doc, etc.

Examples that route to the right tools:

```
Pull the color and spacing variables from
https://www.figma.com/file/AbC123XyZ/Design-System
and emit them as a Tailwind theme extension.
```

```
Get the components in https://www.figma.com/design/AbC123XyZ/Design-System
that contain the word "Button". For each, list its variants and which
props they expose.
```

```
For the file at https://www.figma.com/file/AbC123XyZ/Design-System,
check whether the tokens match the values in src/tokens.css and
flag any drift.
```

What the agent has access to (full list under [What works](#what-works) below): variables, styles, components, component sets, file data, design-system kit, design-code parity. All read-only — see [What does NOT work (by design)](#what-does-not-work-by-design).

## Prerequisites

- `podman` ≥ 4.4 (RHEL 9.3+ is fine)
- `podman-compose` ≥ 1.0.6 (only if you want to run via compose; Quadlet doesn't need it)
- A **read-only** Figma personal access token. Create at
  https://www.figma.com/developers/api#access-tokens and grant ONLY:
  - File content: **Read-only**
  - Variables: **Read-only**
  - (optionally) Dev resources, Library content: Read-only

  Do **not** grant any "Write" scopes.

## First-time setup

`compose.yaml` and the Quadlet unit reference the prebuilt amd64 image at `ghcr.io/trick77/figma-console-mcp:latest`. Podman pulls it on first start.

```sh
cp .env.example .env
$EDITOR .env                       # set FIGMA_ACCESS_TOKEN
podman-compose up -d               # pulls + starts
./scripts/install-opencode.sh      # writes the OpenCode MCP entry
```

> **Behind a TLS-intercepting corporate proxy?** The published image has no corporate CAs baked in, so api.figma.com calls will fail with cert errors. Build locally instead — see [Building from source](#building-from-source).

Then restart OpenCode. The MCP server appears as `figma-console-mcp` and points at `http://127.0.0.1:23148/mcp`.

Day-to-day:

```sh
podman-compose ps
podman-compose logs -f
podman-compose restart
podman-compose down
```

For boot-time auto-start (rootless Quadlet, recommended for workstations that should have the service available without logging in):

```sh
./scripts/install-systemd.sh       # one-shot: linger, drop Quadlet, enable
systemctl --user status figma-console-mcp.service
journalctl --user -u figma-console-mcp.service -f
```

Use **either** podman-compose **or** the Quadlet — not both at once on the same machine, they'd collide on the container name and the published port.

## How it works (1-minute version)

1. Quadlet boots `ghcr.io/trick77/figma-console-mcp:latest` and publishes `127.0.0.1:23148:8000`.
2. Inside the container, `mcp-proxy` listens on `:8000`.
3. OpenCode reads `~/.config/opencode/opencode.json`, sees the remote MCP entry, opens a streamable-http connection to `http://127.0.0.1:23148/mcp`, sends `initialize` → `tools/list`.
4. mcp-proxy spawns `node /app/dist/local.js` for that session, with `FIGMA_ACCESS_TOKEN` already in env (forwarded from `.env` via `--pass-environment`). The child enumerates tools and serves `tools/call`s for the rest of the session.
5. When OpenCode disconnects, the child exits. The container stays up.

One MCP client session = one persistent node child. Three concurrent clients = three children. Hard ceilings (`MemoryMax=512M`, `CPUQuota=100%`, `PidsLimit=64`) are set in the Quadlet unit.

## Updates

If you're using the prebuilt image:

```sh
podman pull ghcr.io/trick77/figma-console-mcp:latest
podman-compose up -d --force-recreate       # or: systemctl --user restart figma-console-mcp.service
```

If you build locally:

```sh
./scripts/update.sh v1.22.3                 # any tag from southleft/figma-console-mcp releases
podman-compose up -d --force-recreate       # or: systemctl --user restart figma-console-mcp.service
```

`update.sh` writes `VERSION=v1.22.3` into `.env`, rebuilds the image with fresh corporate CAs, and prunes dangling layers. `podman auto-update` is **intentionally not used** — the image is built/pulled on a controlled host, never refreshed at runtime.

## What works

Read-only Figma API tools:

- `figma_get_variables`, `figma_get_styles`
- `figma_get_component`, `figma_get_component_set`, `figma_get_component_usages`
- `figma_get_file_data`, `figma_get_file_for_plugin`
- `figma_get_design_system_kit`
- `figma_check_design_parity`, `figma_generate_component_doc`
- `figma_get_status`

## What does NOT work (by design)

- All write operations (create / update / delete / arrange / post)
- FigJam / Slides creation
- Desktop Bridge tools: console logs, screenshots, `figma_execute`

Note that `tools/list` will still **advertise** these — upstream's `dist/local.js` registers its full tool set unconditionally and the wrapper does not filter the list. They fail at *call* time, not at *list* time:

1. **Bridge tools have no peer.** `figma_execute`, `figma_get_console_logs`, `figma_take_screenshot`, etc. depend on a Desktop Bridge WebSocket connection to a running Figma Desktop. The wrapper never starts that listener and the bridge plugin source isn't copied into the runtime image, so a bridge call has nothing to connect to.
2. **REST writes lack scope.** `figma_create_*`, `figma_post_comment`, `figma_update_*`, etc. ultimately hit `api.figma.com`. The PAT in `.env` carries only read scopes, so Figma rejects writes server-side with 403.

An agent may try a write tool, get a clear error back, and move on — that's the intended behavior.

## No third-party endpoints

At runtime the container talks to **one** external host:

- `api.figma.com` — Figma's own REST API, using your PAT, against your own
  Figma account.

Cloud Mode and Remote SSE (which use `*.southleft.com`) are upstream features
we deliberately do not build or invoke — only `dist/local.js` is executed.
There is no telemetry, no auto-update, no OAuth proxy.

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
podman run --rm --entrypoint sh ghcr.io/trick77/figma-console-mcp:latest -c \
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

## Hardening

Identical flags in `compose.yaml` and `systemd/figma-console-mcp.container` (so podman-compose and Quadlet both apply them). Don't `podman run` this image directly — you'd lose the hardening; always go through compose or the Quadlet.

- `read_only` rootfs. Two throwaway tmpfs mounts (`/tmp`, `/home/node/.figma-console-mcp`) discarded on container exit.
- `cap_drop: ALL`, `no-new-privileges`. Runs as non-root `node` user.
- No host bind mounts. The server cannot read your `$HOME`, SSH keys, or any other on-disk credentials.
- Resource ceilings: `mem_limit=512M`, `cpus=1.0`, `pids_limit=64` (and the matching `MemoryMax`/`CPUQuota`/`PidsLimit` in the Quadlet). mcp-proxy + every spawned node child combined cannot exceed these.
- Loopback-only port publish (`127.0.0.1:23148`).

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
└── AGENTS.md                     # rules for coding agents working on this repo
```

## Building from source

Use this path if you're behind a TLS-intercepting corporate proxy (the prebuilt CI image has no corp CAs baked in), if you want to pin a different upstream version, or if you simply prefer to build on a host you control.

Extra prerequisites for building:

- A build host with corporate root CA(s) in `/etc/pki/ca-trust/source/anchors/`
  (RHEL/Fedora). Debian/Ubuntu and Arch paths are auto-detected; override with
  `HOST_ANCHORS=/path/to/anchors`. The dir may be empty on a non-corporate host —
  `build.sh` will warn and produce an image without corp CAs.

```sh
cp .env.example .env
$EDITOR .env                       # set FIGMA_ACCESS_TOKEN, optionally pin VERSION
./scripts/build.sh
podman-compose up -d
./scripts/install-opencode.sh
```

`build.sh` works with both podman and docker (override with `CONTAINER_ENGINE=docker`). It tags the build as `ghcr.io/trick77/figma-console-mcp:latest` (same name compose.yaml and the Quadlet reference), so the local image transparently shadows the registry one — no further config changes needed.

## Uninstall

```sh
systemctl --user disable --now figma-console-mcp.service
rm ~/.config/containers/systemd/figma-console-mcp.container
systemctl --user daemon-reload
podman rmi ghcr.io/trick77/figma-console-mcp:latest
# Remove "figma-console-mcp" from .mcp in ~/.config/opencode/opencode.json
```
