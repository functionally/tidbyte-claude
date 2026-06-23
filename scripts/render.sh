#!/usr/bin/env bash
# Render one frame to out.webp
set -euo pipefail
cd "$(dirname "$0")/.."

pixlet render main.star -o out.webp
echo "Rendered: $PWD/out.webp"
