#!/usr/bin/env bash
# dist/_lib.sh — shared helpers sourced by every dist/*.sh script.
# Never executed directly.

# Colors (TTY only)
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s ok%s  %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s warn%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s FAIL%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# require_env VAR — fails with helpful message if VAR is empty/unset.
require_env() {
  local name="$1"
  local val
  # ${!name} requires bash 4+; macOS ships 3.2 by default, but our shebang
  # requests env bash which typically resolves to /opt/homebrew/bin/bash if
  # installed. Fall back via eval for portability.
  eval "val=\${$name:-}"
  if [ -z "$val" ]; then
    die "missing required env var: $name (see RELEASE.md for setup)"
  fi
}

# require_cmd command — fails if command not found on PATH.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || die "missing required command: $1 (install via brew or Xcode CLT)"
}

# Standard argument parser. Sets:
#   DRY_RUN=1 if --dry-run was passed
#   Shows help and exits 0 if --help / -h passed
# Caller must set SCRIPT_HELP before calling.
parse_common_args() {
  DRY_RUN="${DRY_RUN:-0}"
  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        printf '%s\n' "${SCRIPT_HELP:-no help available}"
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
    esac
  done
  export DRY_RUN
}

# run "<command>" — execute, or print prefixed "DRY" line if DRY_RUN.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s DRY%s %s\n' "$C_YEL" "$C_RST" "$*" >&2
  else
    eval "$@"
  fi
}

# repo_root — absolute path to the repo root (parent of dist/).
repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ( cd "$here/.." && pwd )
}

# version_from_tag — read version from CI tag (GITHUB_REF) or VERSION env or
# fall back to MARKETING_VERSION in project.yml.
version_from_tag() {
  if [ -n "${VERSION:-}" ]; then
    printf '%s' "$VERSION"
    return
  fi
  if [ -n "${GITHUB_REF_NAME:-}" ]; then
    # strip leading 'v'
    printf '%s' "${GITHUB_REF_NAME#v}"
    return
  fi
  if [ -n "${GITHUB_REF:-}" ]; then
    local tag="${GITHUB_REF##refs/tags/}"
    printf '%s' "${tag#v}"
    return
  fi
  # fall back to project.yml MARKETING_VERSION
  local root mv
  root="$(repo_root)"
  mv=$(grep -E '^\s*MARKETING_VERSION:' "$root/apps/macos/project.yml" 2>/dev/null \
        | head -1 | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/')
  printf '%s' "${mv:-0.0.0-dev}"
}
