#!/usr/bin/env bash
# Social cards share the approved app artwork and the brand exporter.
# No separate browser session or network font download is needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
node "$HERE/../scripts/build-brand.mjs"
