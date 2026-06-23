#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-claudestat}"
PUSH_INTERVAL_S="${PUSH_INTERVAL_S:-600}"

DETACH=""
RESTART_POLICY="no"
for arg in "$@"; do
  case "$arg" in
    --detach|-d)
      DETACH="--detach"
      RESTART_POLICY="always"
      ;;
    --once)
      PUSH_INTERVAL_S=999999999
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      echo "Usage: $0 [--detach|-d] [--once]" >&2
      exit 1
      ;;
  esac
done

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH." >&2
  exit 1
fi

if ! podman image exists claudestat:latest; then
  echo "ERROR: claudestat:latest is not loaded. Run ./scripts/build-container.sh first." >&2
  exit 1
fi

if podman container exists "$CONTAINER_NAME"; then
  echo "Removing existing container ${CONTAINER_NAME}…"
  podman rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting ${CONTAINER_NAME} (push every ${PUSH_INTERVAL_S}s)…"
exec podman run \
  --name "$CONTAINER_NAME" \
  --rm \
  ${DETACH} \
  --restart="$RESTART_POLICY" \
  -e "PUSH_INTERVAL_S=${PUSH_INTERVAL_S}" \
  claudestat:latest
