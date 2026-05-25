# Myna

Always-on, fully local text-to-speech companion for macOS (Apple Silicon).
Reads selections, web articles, and Claude Code output aloud through
Kokoro (mlx-audio) — zero API cost, controlled from the menu bar and
recordable global hotkeys.

## What it does

- **Speak any selection** — select text in any app, press the hotkey, listen.
- **Read Chrome articles** — one hotkey reads the current page's main article.
- **Claude Code, on your terms** — parallel sessions announce their replies
  silently into the menu bar; you click the one you want to hear (full or
  summary). They never all talk at once.
- **Full or summary** — separate triggers; summaries run locally via Ollama.
- **Controls** — pause / resume / stop / speed from the menu bar or hotkeys.

## Architecture

```
Adapters (hotkeys, CLI, CC hook)  ->  myna daemon (:8766)  ->  mlx-audio (:8765)
Hammerspoon menu bar  <- /status -'
```

- **Engine** — mlx-audio Kokoro server (`af_heart`), 24/7 via LaunchAgent.
- **Brain** — Python FastAPI daemon: extract -> summarise -> chunk -> play,
  plus the Claude announce/pick registry.
- **Surface** — Hammerspoon menu bar + recordable hotkeys; `myna` CLI; CC Stop hook.

## Prerequisites

- Apple Silicon Mac, macOS.
- The existing mlx-audio venv at `~/.venvs/mlx-audio` with Kokoro cached
  (see `docs/superpowers/specs/2026-05-24-myna-design.md`).
- Python 3.13 at `~/.local/bin/python3.13`.
- [Hammerspoon](https://www.hammerspoon.org) (free).
- [Ollama](https://ollama.com) with `qwen3.5:4b` (summary mode only).

## Install

```bash
git clone <repo-url> ~/Developer/myna
cd ~/Developer/myna
./install.sh
```

Then open Hammerspoon, Reload Config, grant Accessibility permission, and
enable **Launch Hammerspoon at login** (Hammerspoon → Preferences) so the
menu bar and hotkeys survive reboots.

## Default shortcuts (all rebindable)

| Action | Default |
|---|---|
| Speak selection (full) | ⌘⌥⇧S |
| Speak selection (summary) | ⌘⌥⇧A |
| Read Chrome article | ⌘⌥⇧R |
| Pause / Resume | ⌘⌥⇧Space |
| Stop | ⌘⌥⇧. |

Defaults use ⌘⌥⇧ (Command-Option-Shift) to avoid clashing with app shortcuts. The menu-bar icon is a Myna bird; Hammerspoon's Dock icon is hidden so Myna runs as a background menu-bar app.

Rebind any of them: menu bar → **Customize Shortcuts…** → pick an action →
press the new chord.

## CLI

```bash
myna "Read this aloud."
pbpaste | myna
myna --summary "Long text to condense first."
myna --speed 1.25 "Faster reading."
```

## Config

- `~/.config/myna/config.json` — voice, speed, summary model, ports, and the
  summariser controls `summary_think` (default `false` — disables the reasoning
  model's "thinking" phase so a summary returns in seconds instead of minutes;
  set `true` for slower, higher-effort summaries) and `summary_timeout`.
- `~/.config/myna/keybindings.json` — recorded shortcuts.
- Logs: `~/Library/Logs/myna-{engine,daemon}.log`.

## Status

The daemon, adapters, control surface, and installer are built and tested
(33 automated tests). The remaining work is the one-time guided install on a
machine: running `install.sh`, installing/reloading Hammerspoon, granting
Accessibility, enabling launch-at-login, and confirming each integration
speaks. Not yet published to GitHub.
