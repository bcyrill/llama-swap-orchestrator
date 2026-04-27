#!/usr/bin/env bash
# Configure rootless Podman to expose NVIDIA GPUs via CDI.
# Run once per host (re-run if you upgrade the NVIDIA driver / toolkit).
#
# Prereqs (install separately, distro-specific):
#   - NVIDIA driver
#   - nvidia-container-toolkit  (provides nvidia-ctk)
# See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

set -euo pipefail

if ! command -v podman >/dev/null 2>&1; then
  echo "podman not found. Install Podman first." >&2
  exit 1
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  cat >&2 <<'EOF'
nvidia-ctk not found.

Install nvidia-container-toolkit, e.g. on Ubuntu/Debian:
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

On Fedora/RHEL:
  sudo dnf install -y nvidia-container-toolkit
EOF
  exit 1
fi

echo ">>> Generating CDI spec at /etc/cdi/nvidia.yaml"
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

echo ">>> CDI devices visible to Podman:"
nvidia-ctk cdi list || true

echo ">>> Smoke test: podman run nvidia/cuda nvidia-smi"
podman run --rm \
  --device nvidia.com/gpu=all \
  --security-opt=label=disable \
  docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
  nvidia-smi

echo ">>> GPU access OK."
