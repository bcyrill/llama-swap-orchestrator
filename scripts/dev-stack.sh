#!/usr/bin/env bash
#
# dev-stack.sh — bring up podman-socket-proxy + llama-swap rootless,
# without Quadlets / systemd / /etc. Everything lives under
# $XDG_RUNTIME_DIR/llama-swap-dev and is torn down with `down`.
#
# What it does:
#   - bind-mounts your rootless podman socket into the proxy as upstream
#   - shares a listen-socket directory between proxy and llama-swap
#     (`Volume=… :z`)
#   - publishes llama-swap on a host port (default 127.0.0.1:9292)
#   - rewrites the production configs on the fly:
#       * strips --uidmap/--gidmap from llama-swap/config.yaml
#         (rootless can't use absolute host UIDs unless they fit in
#         the user's subuid block — easier to drop them and rely on
#         rootless's per-user namespace isolation)
#       * forces listen_socket_mode back to "0660" in
#         socket-proxy/config.yaml (no UidMap means no need for the
#         world bit)
#       * substitutes "/srv/llama-models" with $LLAMA_MODELS_DIR
#         throughout socket-proxy/config.yaml so the proxy's
#         binds.allowed_sources matches whatever path llama-swap
#         actually bind-mounts from. Without this, any test on a
#         non-default LLAMA_MODELS_DIR 403s on every spawn.
#
# Usage:
#   scripts/dev-stack.sh             # show this help
#   scripts/dev-stack.sh up          # start the stack
#   scripts/dev-stack.sh down        # stop + clean up
#   scripts/dev-stack.sh logs        # follow both logs
#   scripts/dev-stack.sh status      # check what's running
#   scripts/dev-stack.sh fetch [id]  # download GGUF model files
#                                    # (filter optional, e.g. "bge")
#
# Env overrides:
#   PUBLISH=127.0.0.1:9292:9292      bind addr for llama-swap (default)
#   LLAMA_MODELS_DIR=$HOME/llama-models  passed through to llama-swap
#                                    (rootless-friendly default; override
#                                    if your models are elsewhere)
#   HF_TOKEN=…                       passed through to llama-swap
#   GPU=1                            (default) keep --device nvidia.com/gpu=all
#                                    on every model command. Set GPU=0 on a
#                                    box without an NVIDIA GPU + CDI; the
#                                    --device flag is stripped from the
#                                    llama-swap config on the fly. The model
#                                    container itself may still fail to run
#                                    on CPU depending on the runtime image
#                                    (the shipped llama.cpp image is
#                                    server-cuda) — that's downstream of
#                                    the proxy and out of scope here.
#   PROXY_NAME / LLAMA_NAME          override container names
#   NETWORK=llama-swap-internal      podman network for orchestrator+models
#
# Prereqs:
#   - rootless podman + user socket up:
#       systemctl --user enable --now podman.socket
#   - both images built locally:
#       ./socket-proxy/build-image.sh
#       ./llama-swap/build-image.sh
#   - model images pre-pulled as your user (no sudo):
#       ./scripts/pull-images.sh
#   - if you actually want models to start, GPU CDI must work rootless
#     (nvidia-ctk runtime configure --runtime=podman, etc.); without
#     that the stack still comes up, but `podman run` on a model fails
#     when llama-swap tries to load one.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# --- Defaults ---------------------------------------------------------------

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
RUNTIME="$XDG_RUNTIME_DIR/llama-swap-dev"
SOCKDIR="$RUNTIME/sock"
LLAMA_CFG="$RUNTIME/llama-swap-config.yaml"
PROXY_CFG="$RUNTIME/socket-proxy-config.yaml"

PROXY_NAME="${PROXY_NAME:-podman-socket-proxy-dev}"
LLAMA_NAME="${LLAMA_NAME:-llama-swap-dev}"
NETWORK="${NETWORK:-llama-swap-internal}"
PUBLISH="${PUBLISH:-127.0.0.1:9292:9292}"

PROXY_IMAGE="${PROXY_IMAGE:-localhost/podman-socket-proxy:latest}"
LLAMA_IMAGE="${LLAMA_IMAGE:-localhost/llama-swap-orchestrator:latest}"

# Default model dir under $HOME so a rootless user can write to it
# without sudo. The committed proxy policy ships /srv/llama-models
# (the production default), but dev-stack rewrites it on the fly to
# whatever LLAMA_MODELS_DIR points at — so this default value just
# needs to be writable by the calling user. Override with
# LLAMA_MODELS_DIR=/wherever if you have models elsewhere.
LLAMA_MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/llama-models}"
HF_TOKEN="${HF_TOKEN:-}"
GPU="${GPU:-1}"

UPSTREAM_SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"

# Manual-download GGUFs for the llama.cpp models. vLLM and SGLang
# pull HuggingFace weights themselves at first spawn (egress from
# inside the model container — out of the proxy's scope), so they're
# not listed here. Format: <hf-repo>:<filename>.
declare -A LLAMACPP_GGUF=(
  [llamacpp-qwen2.5-7b]="bartowski/Qwen2.5-7B-Instruct-GGUF:Qwen2.5-7B-Instruct-Q5_K_M.gguf"
  [llamacpp-bge-reranker]="gpustack/bge-reranker-v2-m3-GGUF:bge-reranker-v2-m3-Q8_0.gguf"
)
ALL_MODEL_IDS=(
  llamacpp-qwen2.5-7b
  llamacpp-bge-reranker
  vllm-llama3.1-8b
  sglang-qwen2.5-14b
)

# --- Subcommands ------------------------------------------------------------

usage() {
  # Print the comment block from "# Usage:" up to (but not including) the
  # "# Prereqs:" line, then strip the leading "# " from each line.
  sed -n '/^# Usage:/,/^# Prereqs:/{/^# Prereqs:/!p;}' "$0" \
    | sed 's/^# \{0,1\}//' >&2
}

cmd_down() {
  echo ">>> stopping ${LLAMA_NAME} and ${PROXY_NAME}"
  podman stop -t 30 "$LLAMA_NAME" 2>/dev/null || true
  podman stop -t 5  "$PROXY_NAME" 2>/dev/null || true
  podman rm -f "$LLAMA_NAME" "$PROXY_NAME" 2>/dev/null || true
  rm -rf "$RUNTIME"
  echo ">>> done."
}

cmd_logs() {
  if ! podman container exists "$PROXY_NAME"; then
    echo "ERR: proxy container $PROXY_NAME isn't running. Run \`$0 up\` first." >&2
    exit 1
  fi
  echo "--- following $PROXY_NAME + $LLAMA_NAME ---  (Ctrl-C to stop)"
  podman logs -f "$PROXY_NAME" 2>&1 | sed 's/^/[proxy]      /' &
  P1=$!
  podman logs -f "$LLAMA_NAME" 2>&1 | sed 's/^/[llama-swap] /' &
  P2=$!
  trap 'kill $P1 $P2 2>/dev/null || true' EXIT INT TERM
  wait
}

cmd_status() {
  echo "  proxy:      $(podman ps --filter "name=^${PROXY_NAME}$" --format '{{.Names}} ({{.Status}})' || true)"
  echo "  llama-swap: $(podman ps --filter "name=^${LLAMA_NAME}$" --format '{{.Names}} ({{.Status}})' || true)"
  echo "  network:    $(podman network exists "$NETWORK" && echo "$NETWORK exists" || echo "$NETWORK absent")"
  echo "  socket:     $SOCKDIR/podman.sock $([ -S "$SOCKDIR/podman.sock" ] && echo OK || echo MISSING)"
}

# --- Fetch model weights ----------------------------------------------------

# Download a single file from a HuggingFace repo to a target path. Tries
# huggingface-cli first (best for large files — handles resume + parallel
# chunks), falls back to curl, then wget. Caller is responsible for the
# target directory existing.
fetch_hf() {
  local repo="$1" file="$2" target="$3"
  local target_dir; target_dir="$(dirname "$target")"
  if command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$repo" "$file" \
      --local-dir "$target_dir" \
      --local-dir-use-symlinks False
  elif command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar --output "$target" \
      "https://huggingface.co/${repo}/resolve/main/${file}"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress --output-document="$target" \
      "https://huggingface.co/${repo}/resolve/main/${file}"
  else
    echo "ERR: need one of huggingface-cli, curl, or wget on PATH" >&2
    return 1
  fi
}

# fetch [filter]
#
# Creates LLAMA_MODELS_DIR/gguf/ and per-model LLAMA_MODELS_DIR/hf-cache/
# subdirs, then downloads GGUF files for the llama.cpp models. With no
# argument, fetches every entry in LLAMACPP_GGUF. With an argument,
# fetches only model ids whose name contains the substring.
#
# vLLM and SGLang weights are auto-downloaded by those runtimes on first
# spawn — set HF_TOKEN before `up` for the gated meta-llama repo.
cmd_fetch() {
  local filter="${1:-}"

  mkdir -p "$LLAMA_MODELS_DIR/gguf"
  for mid in "${ALL_MODEL_IDS[@]}"; do
    mkdir -p "$LLAMA_MODELS_DIR/hf-cache/$mid"
  done
  echo ">>> ensured $LLAMA_MODELS_DIR/{gguf,hf-cache/<model>} exist"

  local matched=0
  for mid in "${!LLAMACPP_GGUF[@]}"; do
    if [[ -n "$filter" && "$mid" != *"$filter"* ]]; then
      continue
    fi
    matched=$((matched + 1))
    local entry="${LLAMACPP_GGUF[$mid]}"
    local repo="${entry%%:*}"
    local file="${entry##*:}"
    local target="$LLAMA_MODELS_DIR/gguf/$file"

    if [[ -f "$target" && -s "$target" ]]; then
      echo ">>> $file already present (skipping; rm to re-download)"
      continue
    fi
    echo ">>> fetching $file"
    echo "    repo:   $repo"
    echo "    target: $target"
    fetch_hf "$repo" "$file" "$target" || {
      echo "ERR: fetch of $file failed" >&2
      return 1
    }
  done

  if [[ -n "$filter" && $matched -eq 0 ]]; then
    echo "ERR: filter '$filter' didn't match any model id." >&2
    echo "     known: ${!LLAMACPP_GGUF[*]}" >&2
    return 2
  fi

  echo ">>> done."
  if [[ -n "$HF_TOKEN" ]]; then
    return 0
  fi
  echo
  echo "Note: vllm-llama3.1-8b uses meta-llama/Llama-3.1-8B-Instruct,"
  echo "      a gated HuggingFace repo. Set HF_TOKEN in your environment"
  echo "      and accept the EULA at huggingface.co/meta-llama before its"
  echo "      first spawn, or that model will fail to download its weights."
}

# --- Main "up" flow ---------------------------------------------------------

cmd_up() {
  # Sanity checks.
  if ! systemctl --user is-active podman.socket >/dev/null 2>&1; then
    echo "ERR: rootless podman.socket isn't active." >&2
    echo "     systemctl --user enable --now podman.socket" >&2
    exit 1
  fi
  if [[ ! -S "$UPSTREAM_SOCK" ]]; then
    echo "ERR: rootless podman socket missing at $UPSTREAM_SOCK" >&2
    exit 1
  fi
  if ! podman image exists "$PROXY_IMAGE"; then
    echo "ERR: $PROXY_IMAGE not built. Run socket-proxy/build-image.sh" >&2
    exit 1
  fi
  if ! podman image exists "$LLAMA_IMAGE"; then
    echo "ERR: $LLAMA_IMAGE not built. Run llama-swap/build-image.sh" >&2
    exit 1
  fi
  if [[ ! -f "$REPO/socket-proxy/config.yaml" || ! -f "$REPO/llama-swap/config.yaml" ]]; then
    echo "ERR: socket-proxy/config.yaml or llama-swap/config.yaml missing" >&2
    exit 1
  fi

  # Tear down any prior instance so the script is idempotent.
  podman rm -f "$LLAMA_NAME" "$PROXY_NAME" 2>/dev/null || true

  # Prep runtime dir + ad-hoc rootless configs.
  mkdir -p "$SOCKDIR"

  # Build the llama-swap config rewrite. Always strip --uidmap/--gidmap
  # (rootless can't use absolute host UIDs); optionally also drop
  # `--device nvidia.com/gpu=all` from gpu_flags when GPU=0.
  LLAMA_SED='/--uidmap/d; /--gidmap/d'
  if [[ "$GPU" == "0" ]]; then
    LLAMA_SED="${LLAMA_SED}; "'s|^  gpu_flags: "--device nvidia.com/gpu=all --security-opt=label=disable"|  gpu_flags: "--security-opt=label=disable"|'
    echo ">>> GPU=0: stripping --device nvidia.com/gpu=all from llama-swap gpu_flags"
  fi
  sed "$LLAMA_SED" "$REPO/llama-swap/config.yaml" > "$LLAMA_CFG"

  # Rewrite the proxy policy:
  #   - flip listen_socket_mode 0666 -> 0660 (llama-swap is no longer
  #     UidMapped in dev-stack — both containers run as the calling
  #     user in rootless, so the world bit isn't needed)
  #   - swap "/srv/llama-models" (the production default in the
  #     committed policy) for whatever path the operator pointed
  #     LLAMA_MODELS_DIR at, so the proxy's binds.allowed_sources
  #     matches what llama-swap will actually emit. Without this, a
  #     test on a non-default path 403s on every spawn.
  LMD_ESC=$(printf '%s' "$LLAMA_MODELS_DIR" | sed -e 's/[\\&|]/\\&/g')
  sed -e "s|/srv/llama-models|${LMD_ESC}|g" \
      -e 's/^  listen_socket_mode: "0666"/  listen_socket_mode: "0660"/' \
      "$REPO/socket-proxy/config.yaml" > "$PROXY_CFG"

  # Warn (don't fail) if LLAMA_MODELS_DIR or its expected subdirs
  # are missing. The proxy + llama-swap stack still comes up — useful
  # for testing the policy plumbing without real models — but model
  # spawns will hit the daemon's `statfs <source>: no such file or
  # directory` before reaching the model code.
  if [[ ! -d "$LLAMA_MODELS_DIR" ]]; then
    echo "warn: LLAMA_MODELS_DIR=$LLAMA_MODELS_DIR doesn't exist on host." >&2
    echo "      Proxy + llama-swap will start, but model spawns will" >&2
    echo "      fail at the bind-mount step (statfs)." >&2
  elif [[ ! -d "$LLAMA_MODELS_DIR/gguf" ]]; then
    echo "warn: $LLAMA_MODELS_DIR exists but $LLAMA_MODELS_DIR/gguf is missing." >&2
    echo "      llama.cpp model spawns will fail at the bind-mount step." >&2
  fi

  # Network for llama-swap + spawned model containers. Persistent across
  # runs — `down` doesn't remove it (other workloads might share it).
  if ! podman network exists "$NETWORK"; then
    echo ">>> creating network $NETWORK"
    podman network create "$NETWORK" >/dev/null
  fi

  # --- Run proxy ---
  echo ">>> starting $PROXY_NAME"
  podman run -d \
    --name "$PROXY_NAME" \
    --read-only \
    --tmpfs /tmp:rw,size=16m,mode=1777 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    -v "$UPSTREAM_SOCK:/run/upstream/podman.sock:ro" \
    -v "$SOCKDIR:/run/socket-proxy:z" \
    -v "$PROXY_CFG:/etc/socket-proxy/config.yaml:ro" \
    "$PROXY_IMAGE" >/dev/null

  echo -n ">>> waiting for proxy listen socket... "
  for _ in $(seq 1 30); do
    [ -S "$SOCKDIR/podman.sock" ] && break
    sleep 0.5
  done
  if [[ ! -S "$SOCKDIR/podman.sock" ]]; then
    echo "FAILED."
    echo "--- last proxy logs ---"
    podman logs --tail 40 "$PROXY_NAME"
    exit 1
  fi
  echo "ok"

  # --- Run llama-swap ---
  echo ">>> starting $LLAMA_NAME"
  podman run -d \
    --name "$LLAMA_NAME" \
    --network "$NETWORK" \
    --publish "$PUBLISH" \
    -v "$SOCKDIR:/run/podman:z" \
    -v "$LLAMA_CFG:/etc/llama-swap/config.yaml:ro" \
    -e "LLAMA_MODELS_DIR=$LLAMA_MODELS_DIR" \
    -e "HF_TOKEN=$HF_TOKEN" \
    "$LLAMA_IMAGE" >/dev/null

  # Parse PUBLISH ("host:hostPort:containerPort" or "hostPort:containerPort")
  # into a usable URL.
  IFS=':' read -ra _PARTS <<< "$PUBLISH"
  case ${#_PARTS[@]} in
    3) URL_HOST="${_PARTS[0]}"; URL_PORT="${_PARTS[1]}" ;;
    2) URL_HOST="0.0.0.0";       URL_PORT="${_PARTS[0]}" ;;
    *) URL_HOST="127.0.0.1";     URL_PORT="9292" ;;
  esac
  # 0.0.0.0 isn't a useful URL; show 127.0.0.1 instead.
  [[ "$URL_HOST" == "0.0.0.0" ]] && URL_HOST="127.0.0.1"
  URL="http://${URL_HOST}:${URL_PORT}"

  # Quick liveness check on llama-swap's HTTP listener.
  echo -n ">>> waiting for llama-swap http... "
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "${URL}/v1/models" 2>/dev/null; then
      echo "ok"
      break
    fi
    sleep 0.5
  done

  cat <<EOF

>>> up.

  proxy:       $PROXY_NAME
               listen socket -> $SOCKDIR/podman.sock
               upstream      <- $UPSTREAM_SOCK
  llama-swap:  $LLAMA_NAME
               http          -> ${URL}

Try it:
  curl ${URL}/v1/models
  curl -sN -H 'Content-Type: application/json' \\
       -d '{"model":"llamacpp-qwen2.5-7b","messages":[{"role":"user","content":"hi"}]}' \\
       ${URL}/v1/chat/completions

Watch logs:    $0 logs
Show status:   $0 status
Tear down:     $0 down
EOF
}

# --- Dispatch ---------------------------------------------------------------

case "${1:-}" in
  up|--up)              cmd_up ;;
  down|--down)          cmd_down ;;
  logs|--logs)          cmd_logs ;;
  status)               cmd_status ;;
  fetch|fetch-models)   shift; cmd_fetch "$@" ;;
  ""|-h|--help)         usage; exit 0 ;;
  *)                    usage; exit 2 ;;
esac
