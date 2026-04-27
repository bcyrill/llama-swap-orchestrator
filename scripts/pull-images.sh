#!/usr/bin/env bash
# Pre-pull backend container images so the first model swap doesn't stall
# on a multi-GB image download.
set -euo pipefail

IMAGES=(
  "ghcr.io/ggml-org/llama.cpp:server-cuda"
  "docker.io/vllm/vllm-openai:latest"
  "docker.io/lmsysorg/sglang:latest"
)

for img in "${IMAGES[@]}"; do
  echo ">>> Pulling $img"
  podman pull "$img"
done

echo ">>> Done. Local images:"
podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'llama.cpp|vllm|sglang' || true
