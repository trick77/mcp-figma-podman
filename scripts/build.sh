#!/usr/bin/env bash
# Build the local figma-console-mcp image with corporate CAs baked in.
# Run on a host where /etc/pki/ca-trust/source/anchors/ holds the
# intercepting-proxy root CA(s). The CAs are imported in BOTH the build
# stage (so npm/git over HTTPS work) and the runtime stage (so Node's
# NODE_EXTRA_CA_CERTS sees them when calling api.figma.com).
#
# Works with both podman and docker (BuildKit) — the host CA dir is passed
# as a named build context, not a host bind mount.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_NAME="figma-console-mcp"
HOST_ANCHORS="${HOST_ANCHORS:-/etc/pki/ca-trust/source/anchors}"

# Load .env if present (build-time overrides only; never put secrets here).
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

# Pick the container engine. Override with CONTAINER_ENGINE=docker|podman.
# On hosts that have both (modern ubuntu-latest CI runners ship both), the
# default below picks podman — set CONTAINER_ENGINE=docker if the rest of
# your tooling expects images in docker's local store.
ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    else
        echo "ERROR: neither podman nor docker found." >&2
        exit 1
    fi
fi
if ! command -v "$ENGINE" >/dev/null 2>&1; then
    echo "ERROR: requested container engine '$ENGINE' not found." >&2
    exit 1
fi
[ "$ENGINE" = "docker" ] && export DOCKER_BUILDKIT=1

# If the corp anchors dir doesn't exist (typical on a developer laptop without
# the corporate proxy), fall back to an empty dir so the build still succeeds
# and produces an image — it just won't have corp CAs baked in. The build host
# in production MUST have the real dir; the warning is loud on purpose.
CLEANUP=""
if [ ! -d "$HOST_ANCHORS" ]; then
    echo "WARNING: $HOST_ANCHORS not found. Building WITHOUT corporate CAs." >&2
    echo "         For an enterprise build, set HOST_ANCHORS=/path/to/anchors." >&2
    HOST_ANCHORS="$(mktemp -d)"
    CLEANUP="$HOST_ANCHORS"
    trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
fi

VERSION_TAG="${VERSION:-latest}"

# Default to the public npmjs registry; .env (or the caller's env) can
# override with a corp mirror.
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"

BUILD_ARGS=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")
[ -n "${VERSION:-}" ] && BUILD_ARGS+=(--build-arg "VERSION=${VERSION}")

echo ">> Building ${IMAGE_NAME} via ${ENGINE} (anchors: ${HOST_ANCHORS}, version: ${VERSION_TAG})"
$ENGINE build \
    --build-context "hostcerts=${HOST_ANCHORS}" \
    ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    -t "localhost/${IMAGE_NAME}:local" \
    -t "localhost/${IMAGE_NAME}:${VERSION_TAG}" \
    -f Containerfile \
    .

echo ">> Done."
$ENGINE images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' | grep "${IMAGE_NAME}" || true
