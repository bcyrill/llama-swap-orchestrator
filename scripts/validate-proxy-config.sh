#!/usr/bin/env bash
# Validate socket-proxy/config.yaml by running it through the same
# config.Load + policy.Compile path the proxy uses at startup. Catches
# YAML typos, unknown keys, malformed regexes, references to body or
# pull policies that don't exist, etc., before you ship a broken
# policy to the box.
#
# Usage:
#   scripts/validate-proxy-config.sh
#   SOURCE=/path/to/podman-socket-proxy scripts/validate-proxy-config.sh
#   CONFIG=/etc/podman-socket-proxy/config.yaml scripts/validate-proxy-config.sh
#
# Defaults:
#   CONFIG = <repo>/socket-proxy/config.yaml
#   SOURCE = <repo>/../socket_proxy/socket-proxy   (the dev layout)
#
# Exit code is whatever validate-example returns: 0 on success,
# non-zero with an error message on failure.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

CONFIG="${CONFIG:-${REPO}/socket-proxy/config.yaml}"
SOURCE="${SOURCE:-$(cd "${REPO}/../socket_proxy/socket-proxy" 2>/dev/null && pwd || true)}"

if [[ ! -f "${CONFIG}" ]]; then
  echo "validate-proxy-config.sh: config not found at ${CONFIG}" >&2
  echo "  set CONFIG=/path/to/config.yaml and re-run." >&2
  exit 2
fi
if [[ -z "${SOURCE}" || ! -d "${SOURCE}" ]]; then
  echo "validate-proxy-config.sh: socket-proxy source repo not found." >&2
  echo "  set SOURCE=/path/to/podman-socket-proxy and re-run." >&2
  exit 2
fi
if [[ ! -d "${SOURCE}/cmd/validate-example" ]]; then
  echo "validate-proxy-config.sh: ${SOURCE} doesn't contain cmd/validate-example/" >&2
  echo "  is SOURCE pointing at the right repo?" >&2
  exit 2
fi
if ! command -v go >/dev/null 2>&1; then
  echo "validate-proxy-config.sh: 'go' not on PATH (need Go 1.23+ to build validate-example)." >&2
  exit 2
fi

echo "validate-proxy-config.sh: validating ${CONFIG}"
echo "  via: ${SOURCE}/cmd/validate-example"
( cd "${SOURCE}" && go run ./cmd/validate-example "${CONFIG}" )
