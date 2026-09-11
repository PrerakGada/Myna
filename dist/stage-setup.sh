#!/usr/bin/env bash
# dist/stage-setup.sh — copy what the in-app installer runs into
# apps/macos/Resources/setup/, which Xcode bundles as Contents/Resources/setup:
#
#   setup.sh             the installer (from dist/setup.sh)
#   myna-cc-announce.py  the Claude Code Stop hook (from hooks/)
#   daemon/              the daemon source, installed on Macs without Homebrew
#
# Run by dist/build.sh and apps/macos/dev.sh before every build. The daemon
# and hook copies are gitignored; setup.sh's copy is tracked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/apps/macos/Resources/setup"

mkdir -p "$DEST"
cp "$ROOT/dist/setup.sh" "$DEST/setup.sh"
cp "$ROOT/hooks/myna-cc-announce.py" "$DEST/myna-cc-announce.py"
rm -rf "$DEST/daemon"
mkdir -p "$DEST/daemon"
cp "$ROOT/daemon/pyproject.toml" "$DEST/daemon/pyproject.toml"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$ROOT/daemon/myna" "$DEST/daemon/"

printf 'staged installer files in %s\n' "$DEST" >&2
