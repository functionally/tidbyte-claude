#!/usr/bin/env bash
# Render the current frame and push it to your Tidbyt.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

TIDBYT_API_KEY="$(yq -r '.tidbyt_api_key' config.yaml)"
TIDBYT_DEVICE_ID="$(yq -r '.tidbyt_device_id' config.yaml)"
TIDBYT_INSTALLATION_ID="$(yq -r '.tidbyt_installation_id' config.yaml)"

for name in TIDBYT_API_KEY TIDBYT_DEVICE_ID TIDBYT_INSTALLATION_ID; do
  val="${!name}"
  if [[ -z "$val" || "$val" == "null" || "$val" == YOUR-* ]]; then
    echo "ERROR: $name not set in config.yaml" >&2
    exit 1
  fi
done

if [[ ! "$TIDBYT_INSTALLATION_ID" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ERROR: tidbyt_installation_id must be alphanumeric (a-z, A-Z, 0-9 only)." >&2
  exit 1
fi

echo "Rendering frame…"
pixlet render main.star -o out.webp

echo "Pushing to device ${TIDBYT_DEVICE_ID} as installation ${TIDBYT_INSTALLATION_ID}…"
pixlet push \
  --api-token "${TIDBYT_API_KEY}" \
  --installation-id "${TIDBYT_INSTALLATION_ID}" \
  "${TIDBYT_DEVICE_ID}" \
  out.webp

echo "Done."
