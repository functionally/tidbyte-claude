#!/usr/bin/env bash
# Local browser preview. status.claude.com is unauthenticated so no
# config required — just point a browser at the URL printed below.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PIXLET_PORT:-8080}"
HOST="${PIXLET_HOST:-127.0.0.1}"
BROWSER_HOST="${PIXLET_BROWSER_HOST:-localhost}"

cat <<EOF

Pixlet serving on ${HOST}:${PORT}. Hot-reloads on main.star changes.

Open ONE of these URLs in your browser:

  Pre-filled preview (recommended):
    http://${BROWSER_HOST}:${PORT}/legacy

  Raw rendered frame as WebP:
    http://${BROWSER_HOST}:${PORT}/api/v1/preview.webp

  React SPA (schema form, will be empty):
    http://${BROWSER_HOST}:${PORT}/

Ctrl-C to stop.

EOF

exec pixlet serve -i "${HOST}" -p "${PORT}" main.star
