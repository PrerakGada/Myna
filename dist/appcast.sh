#!/usr/bin/env bash
# dist/appcast.sh — sign a DMG with Sparkle EdDSA and append/emit an appcast item.
#
# Inputs (env):
#   DMG_PATH                     — path to signed DMG to publish
#   SPARKLE_EDDSA_PRIVATE_KEY    — base64-encoded 32-byte Ed25519 private key
#                                  (matches Sparkle's `generate_keys` output)
#   VERSION                      — marketing version
#   BUILD                        — build number (default 1)
#   APPCAST_PATH                 — file to append item to (default dist/out/appcast.xml)
#   DOWNLOAD_BASE_URL            — base URL where DMG will live
#                                  (default https://github.com/<owner>/myna/releases/download/v$VERSION)
#   MIN_SYSTEM_VERSION           — default 13.0
#   RELEASE_NOTES_URL            — optional; link to release notes
#   SIGN_UPDATE_BIN              — optional override for Sparkle's `sign_update`
#   OPENSSL_BIN                  — optional override for openssl. The script
#                                  refuses to use LibreSSL because LibreSSL ≤ 3.x
#                                  cannot sign raw Ed25519 messages via pkeyutl.
#
# Outputs:
#   - Updates / creates $APPCAST_PATH with a new <item> for $VERSION
#   - Prints the signature edSignature value to stdout
#
# Usage:
#   dist/appcast.sh [--dry-run] [--help]
#
# Notes:
#   The official tool is Sparkle's `sign_update` binary; we prefer it when
#   present (the release workflow installs it via the Sparkle release tarball).
#   The OpenSSL fallback requires a real OpenSSL 1.1.1+ that supports Ed25519
#   (Homebrew's openssl@3 works; macOS system /usr/bin/openssl is LibreSSL
#   and does NOT). We auto-detect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

SCRIPT_HELP="$(sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d')"
parse_common_args "$@"

ROOT="$(repo_root)"
VERSION="$(version_from_tag)"
BUILD="${BUILD:-1}"
DMG_PATH="${DMG_PATH:-$ROOT/dist/out/Myna-$VERSION.dmg}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT/dist/out/appcast.xml}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-13.0}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://github.com/CHANGEME/myna/releases/download/v$VERSION}"

log "appcast.sh — version=$VERSION dmg=$DMG_PATH appcast=$APPCAST_PATH"

# ---- locate sign_update (preferred) and openssl (fallback) ----

# 1) sign_update from Sparkle. Either env override, or first found on PATH /
#    in common install locations (brew cellar of Sparkle.app, sparkle tarball
#    extracted to ./sparkle/bin/, the Xcode SPM checkout).
SIGN_UPDATE_BIN="${SIGN_UPDATE_BIN:-}"
if [ -z "$SIGN_UPDATE_BIN" ]; then
  for cand in \
    "$(command -v sign_update 2>/dev/null || true)" \
    "$ROOT/sparkle/bin/sign_update" \
    "/Applications/Sparkle.app/Contents/MacOS/sign_update" \
    "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/checkouts/Sparkle/bin/sign_update
  do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      SIGN_UPDATE_BIN="$cand"
      break
    fi
  done
fi

# 2) openssl. Reject LibreSSL up-front. We prefer brew openssl@3 when present.
OPENSSL_BIN="${OPENSSL_BIN:-}"
if [ -z "$OPENSSL_BIN" ]; then
  for cand in \
    "/opt/homebrew/opt/openssl@3/bin/openssl" \
    "/usr/local/opt/openssl@3/bin/openssl" \
    "$(command -v openssl 2>/dev/null || true)"
  do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      ver="$("$cand" version 2>/dev/null || true)"
      case "$ver" in
        OpenSSL*) OPENSSL_BIN="$cand"; break ;;
      esac
    fi
  done
fi

if [ -n "$SIGN_UPDATE_BIN" ]; then
  log "using sign_update: $SIGN_UPDATE_BIN"
elif [ -n "$OPENSSL_BIN" ]; then
  log "using openssl fallback: $OPENSSL_BIN ($("$OPENSSL_BIN" version))"
else
  if [ "${DRY_RUN:-0}" != "1" ]; then
    die "no signing tool found. Install Sparkle (provides sign_update) or 'brew install openssl@3'."
  fi
  log "no signer found; --dry-run continues with placeholder signature"
fi

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_env SPARKLE_EDDSA_PRIVATE_KEY
  [ -f "$DMG_PATH" ] || die "no DMG at $DMG_PATH"
fi

# ---- compute size + signature ----
file_size=0
ed_sig=""

if [ "${DRY_RUN:-0}" = "1" ]; then
  file_size=12345678
  ed_sig="DRY_RUN_SIGNATURE_PLACEHOLDER_BASE64=="
else
  file_size=$(stat -f '%z' "$DMG_PATH" 2>/dev/null || stat -c '%s' "$DMG_PATH")

  if [ -n "$SIGN_UPDATE_BIN" ]; then
    # Sparkle's `sign_update -f <keyfile> <file>` prints the XML attributes.
    tmp_key=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_key'" EXIT
    printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" > "$tmp_key"
    raw="$("$SIGN_UPDATE_BIN" -f "$tmp_key" "$DMG_PATH" 2>/dev/null || true)"
    rm -f "$tmp_key"
    trap - EXIT
    ed_sig="$(printf '%s\n' "$raw" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
  fi

  if [ -z "$ed_sig" ] && [ -n "$OPENSSL_BIN" ]; then
    # Fallback: build a PKCS#8 PEM from the raw 32-byte seed and sign with
    # `pkeyutl -rawin`. Requires real OpenSSL 1.1.1+; we rejected LibreSSL above.
    tmp_pem=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_pem'" EXIT
    python3 - <<'PY' > "$tmp_pem"
import base64, os, sys
raw = base64.b64decode(os.environ["SPARKLE_EDDSA_PRIVATE_KEY"])
if len(raw) != 32:
    sys.exit(f"SPARKLE_EDDSA_PRIVATE_KEY must decode to 32 bytes, got {len(raw)}")
prefix = bytes.fromhex("302e020100300506032b657004220420")
der = prefix + raw
b64 = base64.b64encode(der).decode()
print("-----BEGIN PRIVATE KEY-----")
for i in range(0, len(b64), 64):
    print(b64[i:i+64])
print("-----END PRIVATE KEY-----")
PY
    sig_bin=$(mktemp)
    "$OPENSSL_BIN" pkeyutl -sign -inkey "$tmp_pem" -rawin -in "$DMG_PATH" -out "$sig_bin"
    ed_sig=$("$OPENSSL_BIN" base64 -A -in "$sig_bin")
    rm -f "$sig_bin" "$tmp_pem"
    trap - EXIT
  fi

  [ -n "$ed_sig" ] || die "signing produced an empty signature — check sign_update / openssl availability"
fi

log "size=$file_size sig=${ed_sig:0:16}..."

# ---- build the <item> XML and write/append to appcast ----
filename="$(basename "$DMG_PATH")"
pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
notes_attr=""
if [ -n "$RELEASE_NOTES_URL" ]; then
  notes_attr="
      <sparkle:releaseNotesLink>$RELEASE_NOTES_URL</sparkle:releaseNotesLink>"
fi

ITEM_XML=$(cat <<XML
    <item>
      <title>Myna $VERSION</title>
      <pubDate>$pub_date</pubDate>$notes_attr
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <enclosure
        url="$DOWNLOAD_BASE_URL/$filename"
        sparkle:edSignature="$ed_sig"
        length="$file_size"
        type="application/octet-stream"/>
    </item>
XML
)

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "would write item to $APPCAST_PATH:"
  printf '%s\n' "$ITEM_XML" >&2
  ok "dry-run complete"
  printf '%s\n' "$ed_sig"
  exit 0
fi

mkdir -p "$(dirname "$APPCAST_PATH")"
if [ ! -f "$APPCAST_PATH" ]; then
  cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Myna</title>
    <link>https://github.com/CHANGEME/myna</link>
    <description>Always-on local TTS companion for macOS</description>
    <language>en</language>
$ITEM_XML
  </channel>
</rss>
XML
else
  # Pass values via env vars rather than heredoc string interpolation so a
  # version tag like `v0.1.0"""` cannot break out of the Python literal.
  # Per AUDIT_REPORT.md Lane B 🟡 #2.
  tmp=$(mktemp)
  ITEM_XML="$ITEM_XML" VERSION="$VERSION" \
  python3 - "$APPCAST_PATH" "$tmp" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
item = os.environ["ITEM_XML"]
ver = os.environ["VERSION"]
# Drop any existing item for the same version, then prepend.
src = re.sub(
    r'\s*<item>.*?<sparkle:shortVersionString>' + re.escape(ver) +
    r'</sparkle:shortVersionString>.*?</item>\s*',
    '\n',
    src,
    flags=re.DOTALL,
)
m = re.search(r'(<channel[^>]*>)', src)
if not m:
    sys.exit("could not find <channel> in existing appcast")
i = m.end()
open(sys.argv[2], "w").write(src[:i] + "\n" + item + src[i:])
PY
  mv "$tmp" "$APPCAST_PATH"
fi

ok "appended item to $APPCAST_PATH"
printf '%s\n' "$ed_sig"
