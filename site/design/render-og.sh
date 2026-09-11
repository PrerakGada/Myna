#!/usr/bin/env bash
# site/design/render-og.sh — re-render the social preview card from og.html
# into app/opengraph-image.png and app/twitter-image.png (1200×630). Next.js
# picks both up by file name. Needs Google Chrome.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="$(cd "$HERE/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1200,630 --virtual-time-budget=8000 \
  --screenshot="$SITE/app/opengraph-image.png" "file://$HERE/og.html" >/dev/null 2>&1
cp "$SITE/app/opengraph-image.png" "$SITE/app/twitter-image.png"
echo "rendered $SITE/app/{opengraph,twitter}-image.png"
