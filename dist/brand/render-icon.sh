#!/usr/bin/env bash
# Export the approved clay icon and companions. Requires npm ci in site/,
# Node 20+, and macOS iconutil. Native release builds use committed exports.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
node "$HERE/../../site/scripts/build-brand.mjs"
