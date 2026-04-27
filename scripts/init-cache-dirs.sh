#!/usr/bin/env bash
# Create per-model directories with the right ownership so each container
# (running with --uidmap 0:BASE:65536) can write to its own cache.
#
# Layout produced under $LLAMA_MODELS_DIR:
#   gguf/                                world-readable, shared, mounted :ro
#   hf-cache/<model-id>/                 chowned to that model's BASE uid/gid
#
# Run as root (or via sudo) once on initial setup, and any time you add a new
# model entry to scripts/uid-ranges.env.
#
# Usage:
#   sudo ./scripts/init-cache-dirs.sh
#   ENV_FILE=/etc/llama-swap/llama-swap.env sudo ./scripts/init-cache-dirs.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ENV_FILE="${ENV_FILE:-$ROOT/.env}"
RANGES_FILE="$HERE/uid-ranges.env"

if [ "$(id -u)" -ne 0 ]; then
  echo "Must be run as root (chown to arbitrary uids)." >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "Env file not found: $ENV_FILE" >&2
  echo "Copy .env.example to .env (or set ENV_FILE=...) and try again." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$ENV_FILE"
: "${LLAMA_MODELS_DIR:?LLAMA_MODELS_DIR must be set in $ENV_FILE}"

# shellcheck disable=SC1090
. "$RANGES_FILE"

GGUF_DIR="$LLAMA_MODELS_DIR/gguf"
HF_CACHE_ROOT="$LLAMA_MODELS_DIR/hf-cache"

mkdir -p "$GGUF_DIR" "$HF_CACHE_ROOT"

# GGUF files are mounted :ro; world-readable is fine.
chmod 0755 "$GGUF_DIR"

# Per-model HF cache subdirs.
for model in "${!LLAMA_SWAP_UIDS[@]}"; do
  base="${LLAMA_SWAP_UIDS[$model]}"
  dir="$HF_CACHE_ROOT/$model"
  mkdir -p "$dir"
  chown -R "$base:$base" "$dir"
  chmod 0700 "$dir"
  echo "ready: $dir   owner=$base:$base   range=$base..$((base + LLAMA_SWAP_RANGE_SIZE - 1))"
done

# Sanity: warn on overlapping ranges.
mapfile -t bases < <(printf '%s\n' "${LLAMA_SWAP_UIDS[@]}" | sort -n)
for ((i=0; i<${#bases[@]}-1; i++)); do
  if (( bases[i] + LLAMA_SWAP_RANGE_SIZE > bases[i+1] )); then
    echo "WARNING: ranges ${bases[i]} and ${bases[i+1]} overlap" >&2
  fi
done

echo "Done."
