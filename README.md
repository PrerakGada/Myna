# Myna

**Listen to your screen.** An always-on, fully local text-to-speech companion for macOS.

Myna lives in your menu bar and reads any selection, any web article, or any Claude Code reply aloud with a single hotkey. Everything happens on your Mac — text never leaves the device.

[Install](#install) · [What it does](#what-it-does) · [Hotkeys](#hotkeys) · [CLI](#cli) · [How it works](#how-it-works)

---

## Install

```sh
brew tap prerakgada/tap
brew trust prerakgada/tap          # Homebrew 6+ requires trusting third-party taps
brew install --cask prerakgada/tap/myna
```

Or grab the signed, notarised DMG from [the latest release](https://github.com/PrerakGada/myna/releases/latest).

Then finish the setup — this installs the on-device voice engine (mlx-audio + the Kokoro model), registers the Claude Code hook, and starts the background services:

```sh
curl -fsSL https://raw.githubusercontent.com/PrerakGada/Myna/v0.3.0/dist/setup.sh | bash
```

It's idempotent, so it's safe to re-run; `myna doctor` checks that the daemon and engine are up.

On first launch Myna walks you through a 60-second spoken intro, asks for Accessibility permission, and then sits quietly in your menu bar.

**Requirements:** macOS 14 (Sonoma) or later · Apple Silicon (M1/M2/M3/M4) — the voice engine (MLX) is Apple-Silicon-only.

---

## What it does

- **Speak any selection** — highlight text in any app, press the hotkey, listen.
- **Read articles** — Chrome or Safari front tab, parsed and read in order.
- **Claude Code, on your terms** — when a Claude Code hook fires, a small playable card slides in from the top-right of your screen. One tap to play, one to dismiss. Parallel sessions stack up to three; nothing ever talks over itself.
- **Full or summary** — separate triggers; summaries run locally via Ollama.
- **Floating pill** — while Myna reads, a slim transport sits at the bottom of the active display. Hover to expand into a mini player; drag it wherever you want.
- **Per-app voices** — pin a different voice per app. Bella for articles, Joe for code, Anna for chat.
- **Karaoke ribbon** (opt-in) — the current spoken line appears at the bottom of your screen, line by line.
- **Voice previews** — audition voices in Settings before committing.
- **Trackpad gestures** (opt-in) — four-finger tap to speak, four-finger double-tap to stop.

---

## Hotkeys

All shortcuts are rebindable from **Settings → Hotkeys**.

| Action | Default |
|---|---|
| Speak selection (full) | ⌘⌥⇧S |
| Speak selection (summary) | ⌘⌥⇧A |
| Read article (front tab) | ⌘⌥⇧R |
| Pause / resume | ⌘⌥⇧Space |
| Stop | ⌘⌥⇧. |

Defaults use ⌘⌥⇧ (Command-Option-Shift) to stay clear of common app shortcuts.

---

## CLI

```sh
myna "Read this aloud."
pbpaste | myna
myna --summary "Long text to condense first."
myna --speed 1.25 "Faster reading."
```

---

## Configuration

- `~/.config/myna/config.json` — voice, speed, summary model, ports
- `~/.config/myna/voice_wardrobe.json` — per-app voice rules
- `~/.config/myna/keybindings.json` — recorded shortcuts
- Logs: `~/Library/Logs/myna-{engine,daemon}.log`

---

## How it works

```
Selection / hotkey / Claude Code event
                  ↓
        Myna.app
        (menu bar · floating pill · settings)
                  ↓
        myna daemon (FastAPI, :8766)
                  ↓
        mlx-audio Kokoro engine (:8765)
```

- **Voice engine** — [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) running on [mlx-audio](https://github.com/ml-explore/mlx-audio). ~80 MB model, runs entirely on the Apple Neural Engine.
- **Daemon** — Python FastAPI service that handles extraction, summarisation, chunking, and streaming. Priority-first chunking returns the first audio in ~240 ms.
- **App** — Swift / SwiftUI menu-bar app with a custom popover, the floating pill, the karaoke sidecar, and global hotkeys (built with [Sindre Sorhus's KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)).
- **Auto-update** — [Sparkle 2](https://sparkle-project.org), EdDSA-signed.

---

## Privacy

- Text and audio stay on your Mac. No telemetry, no network calls except to localhost.
- The daemon binds to `127.0.0.1` only. Firewall-friendly by default.
- Sparkle update checks hit GitHub Releases — that's the only outbound traffic.

---

## Roadmap

Myna is built for macOS Apple Silicon today. Other platforms will follow if there's clear demand. File an [issue](https://github.com/PrerakGada/myna/issues) with feature requests or bug reports.

---

## Develop

```sh
git clone https://github.com/PrerakGada/myna
cd myna

# Daemon
cd daemon && pip install -e . && pytest

# Mac app
cd ../apps/macos && ./dev.sh
```

Project layout, contribution guide, and architecture notes live in [`docs/`](docs/).

---

## License

[MIT](LICENSE). Built by [Prerak Gada](https://github.com/PrerakGada).
