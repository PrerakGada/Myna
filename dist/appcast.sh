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
#
# Outputs:
#   - Updates / creates $APPCAST_PATH with a new <item> for $VERSION
#   - Prints the signature edSignature value to stdout
#
# Usage:
#   dist/appcast.sh [--dry-run] [--help]
#
# Notes:
#   The official tool is Sparkle's `sign_update` binary. We invoke it when
#   present; otherwise we fall back to signing with /usr/bin/openssl which
#   produces the same raw Ed25519 signature Sparkle expects.
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

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_env SPARKLE_EDDSA_PRIVATE_KEY
  [ -f "$DMG_PATH" ] || die "no DMG at $DMG_PATH"
fi

# 1) Compute size + signature.
file_size=0
ed_sig=""

if [ "${DRY_RUN:-0}" = "1" ]; then
  file_size=12345678
  ed_sig="DRY_RUN_SIGNATURE_PLACEHOLDER_BASE64=="
else
  file_size=$(stat -f '%z' "$DMG_PATH" 2>/dev/null || stat -c '%s' "$DMG_PATH")
  if command -v sign_update >/dev/null 2>&1; then
    # Sparkle's binary: prints both `sparkle:edSignature` and `length`.
    raw=$(sign_update -f <(printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY") "$DMG_PATH" 2>/dev/null || true)
    ed_sig=$(printf '%s\n' "$raw" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
  fi
  if [ -z "$ed_sig" ]; then
    # Fallback: openssl sign with raw Ed25519 key.
    # Sparkle accepts the raw 64-byte signature, base64-encoded.
    tmp_pem=$(mktemp)
    trap 'rm -f "$tmp_pem"' EXIT
    # Wrap 32-byte raw key in PKCS#8 DER, then convert to PEM. The PKCS#8
    # prefix for Ed25519 is: 30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20
    python3 - <<PY > "$tmp_pem"
import base64, sys
raw = base64.b64decode("$SPARKLE_EDDSA_PRIVATE_KEY")
assert len(raw) == 32, f"expected 32 bytes, got {len(raw)}"
prefix = bytes.fromhex("302e020100300506032b657004220420")
der = prefix + raw
b64 = base64.b64encode(der).decode()
print("-----BEGIN PRIVATE KEY-----")
for i in range(0, len(b64), 64):
    print(b64[i:i+64])
print("-----END PRIVATE KEY-----")
PY
    sig_bin=$(mktemp)
    /usr/bin/openssl pkeyutl -sign -inkey "$tmp_pem" -rawin -in "$DMG_PATH" -out "$sig_bin"
    ed_sig=$(/usr/bin/openssl base64 -A -in "$sig_bin")
    rm -f "$sig_bin"
  fi
fi

log "size=$file_size sig=${ed_sig:0:16}..."

# 2) Build the <item> XML.
filename="$(basename "$DMG_PATH")"
pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
notes_attr=""
if [ -n "$RELEASE_NOTES_URL" ]; then
  notes_attr="
      <sparkle:releaseNotesLink>$RELEASE_NOTES_URL</sparkle:releaseNotesLink>"
fi

# Use a Python heredoc to write the file safely (escapes XML).
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

# 3) Append to (or create) appcast.xml.
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
  # Insert the new item right after <channel ...> (so newest is first).
  tmp=$(mktemp)
  python3 - "$APPCAST_PATH" "$tmp" <<PY
import sys, re
src = open(sys.argv[1]).read()
item = """$ITEM_XML"""
# Drop any existing item for the same version, then prepend.
src = re.sub(
    r'\s*<item>.*?<sparkle:shortVersionString>' + re.escape("$VERSION") +
    r'</sparkle:shortVersionString>.*?</item>\s*',
    '\n',
    src,
    flags=re.DOTALL,
)
m = re.search(r'(<channel[^>]*>)', src)
if not m:
    sys.exit("could not find <channel> in existing appcast")
i = m.end()
out = src[:i] + "\n" + item + src[i:]
open(sys.argv[2], "w").write(out)
PY
  mv "$tmp" "$APPCAST_PATH"
fi

ok "appended item to $APPCAST_PATH"
printf '%s\n' "$ed_sig"
