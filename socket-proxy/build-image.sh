#!/usr/bin/env bash
#
# build-image.sh — build localhost/podman-socket-proxy:latest from a
# local checkout of the proxy source.
#
# Defaults to the sibling repo at ../../socket_proxy/socket-proxy (where
# this folder's source lives in the working layout). Override with
# SOURCE=/path/to/podman-socket-proxy if your checkout is elsewhere.
#
# About the build: this is a production build regardless of the VERSION
# arg below. The Containerfile does CGO_ENABLED=0 + -trimpath + -ldflags
# "-s -w" — fully static, stripped, no debug symbols. VERSION just
# controls the string the binary reports at startup (main.version);
# there is no separate "dev" build path.
#
# Usage:
#   sudo ./build-image.sh                                   # auto-derive VERSION from git
#   sudo VERSION=v1.0.0 ./build-image.sh                    # pin a label
#   sudo SOURCE=~/code/podman-socket-proxy ./build-image.sh # different checkout
#   sudo TAG=localhost/podman-socket-proxy:v1.0.0 ./build-image.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Default source location: peer of llama_swap_universal/, matching the
# layout used during development.
DEFAULT_SOURCE="$(cd "${HERE}/../../socket_proxy/socket-proxy" 2>/dev/null && pwd || true)"

SOURCE="${SOURCE:-${DEFAULT_SOURCE}}"
TAG="${TAG:-localhost/podman-socket-proxy:latest}"

if [[ -z "${SOURCE}" || ! -d "${SOURCE}" ]]; then
  echo "build-image.sh: socket-proxy source not found." >&2
  echo "  Set SOURCE=/path/to/podman-socket-proxy and re-run." >&2
  exit 1
fi
if [[ ! -f "${SOURCE}/go.mod" || ! -d "${SOURCE}/cmd/socket-proxy" ]]; then
  echo "build-image.sh: ${SOURCE} does not look like the podman-socket-proxy repo" >&2
  echo "  (expected go.mod and cmd/socket-proxy/ to exist)." >&2
  exit 1
fi

# Derive a real version string from the source checkout if possible:
#   - if SOURCE is a git tree:  `git describe --always --dirty`
#                               -> "v1.2.3", "v1.2.3-dirty", or "abcd123"
#   - otherwise:                a stable fallback marking that we don't know
# Override with VERSION=... to pin explicitly.
if [[ -z "${VERSION:-}" ]]; then
  if git -C "${SOURCE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION="$(git -C "${SOURCE}" describe --tags --always --dirty 2>/dev/null || \
               git -C "${SOURCE}" rev-parse --short HEAD)"
  else
    VERSION="unknown"
  fi
fi

echo "build-image.sh: building ${TAG}"
echo "  source:  ${SOURCE}"
echo "  version: ${VERSION}"
echo "  context: ${HERE}/Containerfile"

podman build \
  --tag "${TAG}" \
  --build-arg "VERSION=${VERSION}" \
  --file "${HERE}/Containerfile" \
  "${SOURCE}"

echo "build-image.sh: done. Image:"
podman image inspect --format '  {{.Id}}  {{.RepoTags}}' "${TAG}"
