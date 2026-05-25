#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY313="${PY313:-$HOME/.local/bin/python3.13}"

echo "==> Checking prerequisites"
[ -x "$PY313" ] || { echo "FAIL: $PY313 not found (set PY313=...)"; exit 1; }
[ -d "$HOME/.venvs/mlx-audio" ] || { echo "FAIL: mlx-audio venv missing"; exit 1; }
command -v ollama >/dev/null || echo "WARN: ollama not found (summary mode will fail)"
[ -d "/Applications/Hammerspoon.app" ] \
  || echo "WARN: Hammerspoon not installed — get it at https://www.hammerspoon.org"

echo "==> Creating daemon venv and installing"
[ -d "$HOME/.venvs/myna" ] || "$PY313" -m venv "$HOME/.venvs/myna"
"$HOME/.venvs/myna/bin/pip" install --upgrade pip >/dev/null
"$HOME/.venvs/myna/bin/pip" install -e "$REPO/daemon" >/dev/null

echo "==> Writing default config (only if absent)"
mkdir -p "$HOME/.config/myna"
[ -f "$HOME/.config/myna/keybindings.json" ] || cat > "$HOME/.config/myna/keybindings.json" <<'EOF'
{
  "speak_selection_full":    { "mods": ["cmd","shift"], "key": "s" },
  "speak_selection_summary": { "mods": ["cmd","shift"], "key": "a" },
  "read_chrome_article":     { "mods": ["cmd","shift"], "key": "r" },
  "pause_resume":            { "mods": ["cmd","shift"], "key": "space" },
  "stop":                    { "mods": ["cmd","shift"], "key": "." }
}
EOF

echo "==> Installing CLI"
mkdir -p "$HOME/.local/bin"
chmod +x "$REPO/cli/myna"
ln -sf "$REPO/cli/myna" "$HOME/.local/bin/myna"

echo "==> Installing Hammerspoon module"
mkdir -p "$HOME/.hammerspoon"
cp "$REPO/hammerspoon/myna.lua" "$HOME/.hammerspoon/myna.lua"
grep -q 'require("myna")' "$HOME/.hammerspoon/init.lua" 2>/dev/null \
  || echo 'myna = require("myna"); myna.start()' >> "$HOME/.hammerspoon/init.lua"

echo "==> Registering Claude Code Stop hook"
chmod +x "$REPO/hooks/myna-cc-announce.py"
HOOK="$REPO/hooks/myna-cc-announce.py" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
data = json.loads(p.read_text()) if p.exists() else {}
hooks = data.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
cmd = os.environ["HOOK"]
already = any(
    h.get("command") == cmd
    for group in stop for h in group.get("hooks", [])
)
if not already:
    stop.append({"hooks": [{"type": "command", "command": cmd}]})
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2))
    print("   added Stop hook")
else:
    print("   Stop hook already present")
PY

echo "==> Installing & loading LaunchAgents"
mkdir -p "$HOME/Library/LaunchAgents"
for n in engine daemon; do
  sed "s|__HOME__|$HOME|g" "$REPO/launchagents/dev.myna.$n.plist.template" \
    > "$HOME/Library/LaunchAgents/dev.myna.$n.plist"
  launchctl unload "$HOME/Library/LaunchAgents/dev.myna.$n.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/dev.myna.$n.plist"
done

echo ""
echo "==> Done. Next steps:"
echo "   1. Open Hammerspoon and Reload Config (grant Accessibility if prompted)."
echo "   2. In Hammerspoon Preferences, enable 'Launch Hammerspoon at login'"
echo "      (required for the menu bar + hotkeys to be 24/7 across reboots)."
echo "   3. Ensure ~/.local/bin is on your PATH for the 'myna' command."
echo "   4. Test: myna \"Myna is installed.\""
