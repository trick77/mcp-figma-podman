#!/usr/bin/env bash
# Install the rootless Quadlet unit so the figma-console-mcp container starts
# at boot and exposes streamable-http on 127.0.0.1:23148.
#
# Requirements:
#   - podman >= 4.4 (RHEL 9.3+ is fine)
#   - systemd --user available
#   - .env filled in (FIGMA_ACCESS_TOKEN at minimum)
#   - container image will be pulled from ghcr.io on first start, or use
#     ./scripts/build.sh first to bake corp CAs into a local build
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="$(pwd)/.env"
UNIT_SRC="$(pwd)/systemd/figma-console-mcp.container"
UNIT_DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
UNIT_DEST="${UNIT_DEST_DIR}/figma-console-mcp.container"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and fill in FIGMA_ACCESS_TOKEN first." >&2
    exit 1
fi

if ! grep -qE '^FIGMA_ACCESS_TOKEN=figd_' "$ENV_FILE"; then
    echo "ERROR: $ENV_FILE has no FIGMA_ACCESS_TOKEN=figd_... line." >&2
    echo "Edit it and re-run. Use a READ-ONLY token (see .env.example)." >&2
    exit 1
fi

# 1. Allow this user's systemd to run after logout / on boot.
if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    echo ">> Enabling lingering for $USER (sudo required once)"
    sudo loginctl enable-linger "$USER"
else
    echo ">> Lingering already enabled for $USER"
fi

# 2. Tighten env-file perms — it contains a secret.
chmod 600 "$ENV_FILE"

# 3. Drop the unit in place with the real env-file path baked in.
mkdir -p "$UNIT_DEST_DIR"
sed "s|__ENV_FILE__|${ENV_FILE}|g" "$UNIT_SRC" > "$UNIT_DEST"
echo ">> Installed $UNIT_DEST"

# 4. Reload user systemd so Quadlet generates the .service unit.
systemctl --user daemon-reload

# 5. Enable + start.
systemctl --user enable --now figma-console-mcp.service

echo ">> Status:"
systemctl --user --no-pager status figma-console-mcp.service || true

cat <<EOF

Done. Useful commands:
  systemctl --user status   figma-console-mcp.service
  systemctl --user restart  figma-console-mcp.service
  systemctl --user stop     figma-console-mcp.service
  journalctl --user -u figma-console-mcp.service -f

The streamable-http MCP endpoint is now at http://127.0.0.1:23148/mcp
(loopback only — front it with a reverse proxy if you need remote access).

Next step: run ./scripts/install-opencode.sh to wire OpenCode to that endpoint.
EOF
