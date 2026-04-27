# mcp-figma-podman

Hardened podman wrapper around [`southleft/figma-console-mcp`](https://github.com/southleft/figma-console-mcp). Built for enterprise workstations: corporate CAs baked in at build time, container is `--read-only` with no host access, PAT lives in `.env` (chmod 600), exposed only on `127.0.0.1:23148`.

Upstream speaks stdio only; we bundle [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) to expose streamable-http so the container can run as a long-lived Quadlet service. Native streamable-http transport tracked upstream in [#48](https://github.com/southleft/figma-console-mcp/issues/48).

## Using it

Paste a Figma file URL (`https://www.figma.com/file/<KEY>/...` or `.../design/<KEY>/...`) into your inference client and tell it what you want. Example:

```
Implement the screen at https://www.figma.com/design/AbC123XyZ/Checkout?node-id=12-345
as an Angular component using our internalUX framework. Map each Figma
component instance to the matching internalUX component and match spacing
and colors to the design tokens from the same file.
```

This MCP only covers the Figma side (frames, instances, fills, auto-layout, tokens). The agent pulls internalUX component documentation from a separate MCP server you wire up alongside this one.

Tool reference and capability detail: [southleft/figma-console-mcp](https://github.com/southleft/figma-console-mcp). Write/Bridge tools are advertised but fail at call time — see [What does NOT work](#what-does-not-work-by-design).

## Prerequisites

- `podman` ≥ 4.4
- `podman-compose` ≥ 1.0.6 (compose path only; not needed for Quadlet)
- Figma PAT with read-only scopes: File content, Variables (optionally Dev resources, Library content). No write scopes.

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

Rootless Quadlet for boot-time auto-start. If you cloned the repo, run `./scripts/install-systemd.sh` and skip the rest of this section. Standalone (no clone):

```sh
# 1. Create the env file (chmod 600 — it holds the PAT).
install -m 600 /dev/null ~/.config/figma-console-mcp.env
$EDITOR ~/.config/figma-console-mcp.env       # FIGMA_ACCESS_TOKEN=figd_...

# 2. Drop the Quadlet unit and point it at that env file.
mkdir -p ~/.config/containers/systemd
curl -fsSL https://raw.githubusercontent.com/trick77/mcp-figma-podman/master/systemd/figma-console-mcp.container \
  | sed "s|__ENV_FILE__|$HOME/.config/figma-console-mcp.env|" \
  > ~/.config/containers/systemd/figma-console-mcp.container

# 3. Allow this user's systemd to run after logout / on boot.
sudo loginctl enable-linger "$USER"

# 4. Generate the service from the Quadlet and start it. Quadlet-generated
#    units can't be `enable`d — boot-time autostart is wired by the [Install]
#    section inside the .container file itself.
systemctl --user daemon-reload
systemctl --user start figma-console-mcp.service
```

Operate it with `systemctl --user {status,restart,stop} figma-console-mcp.service` and `journalctl --user -u figma-console-mcp.service -f`.

Use **either** podman-compose **or** the Quadlet — not both at once on the same machine, they'd collide on the container name and the published port.

## How it works

1. Quadlet boots `ghcr.io/trick77/figma-console-mcp:latest` and publishes `127.0.0.1:23148:8000`.
2. Inside the container, `mcp-proxy` listens on `:8000`.
3. The MCP client opens a streamable-http connection to `http://127.0.0.1:23148/mcp` and sends `initialize` → `tools/list`.
4. mcp-proxy spawns `node /app/dist/local.js` per session with `FIGMA_ACCESS_TOKEN` forwarded from `.env` via `--pass-environment`. The child serves `tools/call`s for the session lifetime.
5. On client disconnect the child exits; the container stays up.

One client session = one node child. `TasksMax=128` (Quadlet) / `pids_limit=64` (compose) apply across mcp-proxy and all spawned children.

## Rotating the PAT

Figma personal access tokens expire after 90 days max — rotation is routine, not exceptional. Mint a new read-only token at https://www.figma.com/developers/api#access-tokens, then:

```sh
$EDITOR ~/.config/figma-console-mcp.env       # or wherever your .env lives
                                              # (compose: <repo>/.env)

# Pick the one that matches how you started the service:
systemctl --user restart figma-console-mcp.service       # Quadlet
podman-compose restart                                   # compose
```

Verify the new token works:

```sh
podman exec figma-console-mcp node -e \
  "require('https').get('https://api.figma.com/v1/me', { headers: { 'X-Figma-Token': process.env.FIGMA_ACCESS_TOKEN }}, r => console.log('HTTP', r.statusCode))"
# expect: HTTP 200
```

`install-opencode.sh` prints the exact env-file path it detected at install time — re-run it any time to remind yourself.

## Updates

If you're using the prebuilt image:

```sh
podman pull ghcr.io/trick77/figma-console-mcp:latest
podman-compose up -d --force-recreate       # or: systemctl --user restart figma-console-mcp.service
```

If you build locally:

```sh
./scripts/update.sh v1.20.0                 # any tag from southleft/figma-console-mcp releases
podman-compose up -d --force-recreate       # or: systemctl --user restart figma-console-mcp.service
```

`update.sh` writes `VERSION=v1.20.0` into `.env`, rebuilds the image with fresh corporate CAs, and prunes dangling layers. `podman auto-update` is **intentionally not used** — the image is built/pulled on a controlled host, never refreshed at runtime.

> **Pinned to v1.20.0.** v1.21+ ship a malformed JSON schema for `figma_check_design_parity` (legacy tuple form) that strict LLM providers reject, taking down the entire `tools/list` response. Tracked upstream as [#64](https://github.com/southleft/figma-console-mcp/issues/64). Don't bump past v1.20.0 until that's fixed.

## What does NOT work (by design)

- All write operations (create / update / delete / arrange / post)
- FigJam / Slides creation
- Desktop Bridge tools: console logs, screenshots, `figma_execute`

`tools/list` still advertises these — upstream's `dist/local.js` registers its full tool set unconditionally and the wrapper does not filter. They fail at call time:

1. **Bridge tools have no peer.** `figma_execute`, `figma_get_console_logs`, `figma_take_screenshot`, etc. require a Desktop Bridge WebSocket to a running Figma Desktop. The wrapper never starts that listener and the bridge plugin is not in the runtime image.
2. **REST writes lack scope.** `figma_create_*`, `figma_post_comment`, `figma_update_*`, etc. hit `api.figma.com` and Figma rejects them 403 because the PAT carries only read scopes.

## No third-party endpoints

The container talks to one external host: `api.figma.com`. Cloud Mode and Remote SSE (`*.southleft.com`) are not built or invoked — only `dist/local.js` runs. No telemetry, no auto-update, no OAuth proxy.

## Network posture

Port published as `127.0.0.1:23148:8000` in both `compose.yaml` and the Quadlet unit. The container's internal `0.0.0.0:8000` is in the container netns and is not the host interface.

```sh
ss -ltn 'sport = :23148'                          # only 127.0.0.1:23148 (and/or [::1]:23148)
curl -i http://127.0.0.1:23148/mcp                # 406 = reachable (no Accept header)
curl -i http://<host-external-ip>:23148/mcp       # connection refused
```

For cross-host access, front it with an authenticated reverse proxy on the host. Do not change the bind to `0.0.0.0`.

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

Flags are identical in `compose.yaml` and `systemd/figma-console-mcp.container`.

- `read_only` rootfs; tmpfs mounts at `/tmp` and `/home/node/.figma-console-mcp` discarded on exit.
- `cap_drop: ALL`, `no-new-privileges`, runs as non-root `node`.
- No host bind mounts.
- `pids_limit=64` (compose) / `TasksMax=128` (Quadlet).
- Loopback-only port publish.

## .env

Holds the PAT. `install-systemd.sh` chmods it to `600`. Gitignored.

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

Required for TLS-intercepting corporate proxies (prebuilt CI image has no corp CAs), pinning a different upstream version, or building on a controlled host.

Build host needs corporate root CA(s) in `/etc/pki/ca-trust/source/anchors/` (RHEL/Fedora). Debian/Ubuntu and Arch paths are auto-detected; override with `HOST_ANCHORS=/path/to/anchors`. Empty dir produces an image without corp CAs (warns).

```sh
cp .env.example .env
$EDITOR .env                       # FIGMA_ACCESS_TOKEN, optionally VERSION
./scripts/build.sh
podman-compose up -d
./scripts/install-opencode.sh
```

`build.sh` supports docker via `CONTAINER_ENGINE=docker`. It tags the build as `ghcr.io/trick77/figma-console-mcp:latest`, shadowing the registry image without further config changes.

## Uninstall

```sh
systemctl --user disable --now figma-console-mcp.service
rm ~/.config/containers/systemd/figma-console-mcp.container
systemctl --user daemon-reload
podman rmi ghcr.io/trick77/figma-console-mcp:latest
# Remove "figma-console-mcp" from .mcp in ~/.config/opencode/opencode.json
```
