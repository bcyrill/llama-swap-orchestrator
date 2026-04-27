#!/usr/bin/env bash
# Build the llama-swap orchestrator image locally.
#   sudo ./build-image.sh                       # uses defaults from Containerfile
#   sudo LLAMA_SWAP_VERSION=v208 PODMAN_VERSION=v5.8.2 ./build-image.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLAMA_SWAP_VERSION="${LLAMA_SWAP_VERSION:-v208}"
PODMAN_VERSION="${PODMAN_VERSION:-v5.8.2}"
TAG="${TAG:-localhost/llama-swap-orchestrator:${LLAMA_SWAP_VERSION}}"
LATEST_TAG="${LATEST_TAG:-localhost/llama-swap-orchestrator:latest}"

podman build \
  --build-arg "LLAMA_SWAP_VERSION=${LLAMA_SWAP_VERSION}" \
  --build-arg "PODMAN_VERSION=${PODMAN_VERSION}" \
  -t "$TAG" \
  -t "$LATEST_TAG" \
  -f "$HERE/Containerfile" \
  "$HERE"

echo
echo ">>> built $TAG (also tagged $LATEST_TAG)"
podman images "$TAG" --format '{{.Repository}}:{{.Tag}}\t{{.Size}}'
