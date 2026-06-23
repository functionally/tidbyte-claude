#!/usr/bin/env bash
# Build the OCI image and load it into podman.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

INSTALL_ID="$(yq -r '.tidbyt_installation_id' config.yaml)"
if [[ ! "$INSTALL_ID" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ERROR: tidbyt_installation_id must be alphanumeric (a-z, A-Z, 0-9 only)." >&2
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH." >&2
  exit 1
fi

export CLAUDESTAT_CONFIG_YAML="$(cat config.yaml)"

echo "Building OCI image…"
nix build --impure .#container

echo
echo "Loading image into podman…"
podman load < ./result

echo
echo "Image loaded:"
podman images claudestat:latest

echo
echo "Next: ./scripts/run-container.sh   or   podman kube play --replace claudestat.yaml"
