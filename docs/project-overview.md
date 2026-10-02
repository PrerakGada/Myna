# Myna — Project Overview

**Date:** 2026-05-26
**Type:** Local-first multi-part macOS application + companion site + release pipeline
**Architecture:** Native menu-bar app ↔ local HTTP daemon ↔ local TTS engine, with marketing site and signed/notarized release pipeline

---

## Executive Summary

**Myna** is an always-on, fully local text-to-speech companion for macOS
(Apple Silicon). It reads your selections, web articles, and Claude Code
output aloud through the Kokoro TTS model running locally via mlx-audio
— zero API cost, zero data leaving the device. Users drive it from the
menu bar or recordable global hotkeys.

**The product surface** is a native Swift menu-bar app
(`apps/macos/`); the **brain** is a Python FastAPI daemon
(`daemon/`); the **engine** is mlx-audio's Kokoro server (external,
installed in `~/.venvs/mlx-audio`). The repo also ships a marketing
site (`site/`), a CLI wrapper (`cli/`), a v1 Hammerspoon legacy module
(`hammerspoon/`), a Claude Code Stop hook (`hooks/`), LaunchAgents
(`launchagents/`), and the full release pipeline (`dist/`, `tap/`,
`.github/workflows/`).

**v0.1.0 shipped** on 2026-05-26. The DMG is live on GitHub Releases,
signed + notarized + stapled, distributed via Sparkle auto-update and
`brew install --cask myna`. See [`HANDOFF.md`](https://github.com/PrerakGada/myna/blob/f5860c8/HANDOFF.md) for the
release log and [`STATUS.md`](../STATUS.md) for the overnight build
chronicle.

## Project Classification

- **Repository Type:** multi-part (5 parts in one repo)
- **Project Type(s):** desktop (Swift native app), backend (Python
  FastAPI daemon), web (Next.js site), cli (bash wrapper), infra
  (release pipeline + Homebrew tap + LaunchAgents + CC hook + legacy
  Hammerspoon)
- **Primary Language(s):** Swift 6, Python 3.10+ (3.13 in prod),
  TypeScript 5.7 / React 19, Bash 3.2 (portable), Lua, Ruby (brew
  formulae)
- **Architecture Pattern:** local-first menu-bar app talking to a
  loopback HTTP daemon, which talks to a loopback local TTS engine and
  an optional local summarization engine. Single-user; no auth; no
  cloud; no telemetry.

## Multi-Part Structure

This project consists of **5 distinct parts**, each documented
individually:

### macos — Native Swift menu-bar app
- **Type:** desktop
- **Location:** [`apps/macos/`](../apps/macos/)
- **Purpose:** The user-facing product. Owns hotkeys, audio output,
  selection capture, settings, Sparkle update channel.
- **Tech Stack:** Swift 6, SwiftUI + AppKit, AVAudioEngine + TimePitch,
  Sparkle 2, KeyboardShortcuts (SPM), XcodeGen, OSLog. macOS 13+
  deployment target. Strict concurrency complete, hardened runtime ON.
- **Docs:** [architecture-macos.md](./architecture-macos.md),
  [component-inventory-macos.md](./component-inventory-macos.md),
  [development-guide-macos.md](./development-guide-macos.md)

### daemon — Python FastAPI brain
- **Type:** backend
- **Location:** [`daemon/`](../daemon/)
- **Purpose:** Orchestration brain — text/URL → chunked + streamed WAV
  via Kokoro. Hosts both v1 (legacy /speak etc.) and v2 (multipart
  streaming /v2/synthesize etc.) surfaces.
- **Tech Stack:** Python 3.10+ (3.13 in prod), FastAPI, uvicorn[standard],
  httpx, trafilatura, Pydantic, pytest. 94 tests passing.
- **Docs:** [architecture-daemon.md](./architecture-daemon.md),
  [api-contracts-daemon.md](./api-contracts-daemon.md),
  [data-models-daemon.md](./data-models-daemon.md),
  [development-guide-daemon.md](./development-guide-daemon.md)

### site — Next.js 16 marketing site
- **Type:** web
- **Location:** [`site/`](../site/)
- **Purpose:** Public-facing landing site for the brew-install CTA,
  feature explainer, FAQ, roadmap.
- **Tech Stack:** Next.js 16 (App Router), React 19, TypeScript 5.7,
  Tailwind 3.4. Single-page; 16 hand-rolled SVG/CSS components, no UI
  library, no runtime data fetch beyond a GitHub star count.
- **Docs:** [architecture-site.md](./architecture-site.md),
  [component-inventory-site.md](./component-inventory-site.md),
  [development-guide-site.md](./development-guide-site.md)

### cli — Bash POST wrapper
- **Type:** cli
- **Location:** [`cli/`](../cli/) (just [`cli/myna`](../cli/myna), 27 LOC)
- **Purpose:** Lightweight `myna <text>` / `pbpaste | myna` /
  `myna --summary` / `myna --speed 1.25` CLI; POSTs to the v1
  `/speak` endpoint.
- **Tech Stack:** Bash 3.2 portable + `curl` + an inline Python JSON
  encoder.
- **Docs:** Covered in [architecture-ops.md § 9](./architecture-ops.md)

### Ops — Release pipeline + install + LaunchAgents + legacy
- **Type:** infra
- **Location:** [`dist/`](../dist/), [`tap/`](../tap/),
  [`.github/workflows/`](../.github/workflows/),
  [`launchagents/`](../launchagents/), [`hooks/`](../hooks/),
  [`hammerspoon/`](../hammerspoon/), [`install.sh`](../install.sh)
- **Purpose:** Takes a `git tag v*` push to a fully signed/notarized
  DMG + Sparkle appcast + Homebrew tap bump. Also: local-dev
  installer, Claude Code Stop hook integration, legacy v1 Hammerspoon
  module preserved side-by-side with the Swift app.
- **Tech Stack:** GitHub Actions, bash 3.2 portable shell scripts,
  Apple Developer ID code signing, `xcrun notarytool`, Sparkle 2 EdDSA
  signing, Ruby (Homebrew cask + formula), Lua (Hammerspoon),
  Python (CC hook + install.sh inline JSON merge).
- **Docs:** [architecture-ops.md](./architecture-ops.md),
  [deployment-guide.md](./deployment-guide.md),
  [development-guide-ops.md](./development-guide-ops.md),
  [contribution-guide.md](./contribution-guide.md)

### How Parts Integrate

All runtime integrations are **loopback-only** (`127.0.0.1`). The Swift
app talks to the daemon over HTTP/1.1 (mostly JSON, with
multipart-streaming WAV for `/v2/synthesize`); the daemon talks to
mlx-audio Kokoro and (optionally) Ollama over HTTP. The CLI,
Hammerspoon legacy module, and CC Stop hook all talk to the daemon's v1
surface. The release pipeline integrates with Apple notary, GitHub
Releases, and the Homebrew tap repo over the network. The site is a
pure static deploy on Vercel — no runtime connection to anything else
in the system.

For the complete who-talks-to-whom matrix, sequence diagrams, and
failure-mode chart, see
[integration-architecture.md](./integration-architecture.md).

## Technology Stack Summary

### macos
| Category | Technology | Version | Justification |
|---|---|---|---|
| Language | Swift | 6.0 | Strict concurrency complete; modern actor model |
| OS target | macOS | 13.0+ | Sonoma+ would enable `@Observable` (cleaner), but Ventura preserves a wider install base |
| UI | SwiftUI + AppKit | system | SwiftUI for islands (Settings, MenuBarView, LogViewerView); AppKit for the menu-bar item itself |
| Audio | AVAudioEngine + TimePitch | system | Real seek across chunks, speed without pitch shift — features afplay v1 couldn't do |
| Hotkeys | sindresorhus/KeyboardShortcuts | from 2.0.0 | User-recordable + persistent + conflict-aware |
| Updates | sparkle-project/Sparkle | from 2.6.0 | The reference auto-update framework for macOS; EdDSA-signed |
| Build | XcodeGen | latest brew | Single-source-of-truth project spec; no .xcodeproj merge conflicts |
| Logging | OSLog + file mirror | system + Foundation | Console.app filterable; `~/Library/Logs/Myna/myna.log` for grep |
| Testing | XCTest | system | ~91 tests; integrated with `xcodebuild test` and CI |

### daemon
| Category | Technology | Version | Justification |
|---|---|---|---|
| Language | Python | 3.10+ (3.13 in prod) | FastAPI requires 3.10+; LaunchAgent points at `~/.local/bin/python3.13` |
| Framework | FastAPI | pinned via PyPI sdist in tap | Async-friendly, OpenAPI generation, Pydantic-native |
| ASGI server | uvicorn[standard] | with httptools + uvloop | Single-worker by default; HTTP/1.1 only is enough for loopback |
| Models | Pydantic | v2 | Native to FastAPI; v2_types.py wire contracts |
| HTTP client | httpx | sync-mode | Talks to Kokoro + Ollama; sync because handlers are sync |
| Article extraction | trafilatura | latest | Pure-Python; no headless browser; clean main-content extraction |
| Testing | pytest | latest | 94 tests; shared fixtures with Swift via `docs/native-app/fixtures/` |

### site
| Category | Technology | Version | Justification |
|---|---|---|---|
| Framework | Next.js | ^16.2.6 | App Router; static export friendly; Vercel-native |
| Runtime | React | ^19 | Server Components, hydration improvements |
| Language | TypeScript | ^5.7.2 | Strict mode |
| Styling | Tailwind CSS | ^3.4.16 | Brand palette + utility-first; no design system needed |
| Postprocess | PostCSS + autoprefixer | latest | Standard Tailwind toolchain |
| Hosting | Vercel | n/a | `vercel.json` for headers + framework hint |

### cli
| Category | Technology | Version | Justification |
|---|---|---|---|
| Shell | Bash | 3.2 portable | macOS default bash; no zsh-only constructs |
| HTTP | curl | system | Universally present |
| JSON encoding | python3 -c | system | Avoids jq dep; small script, no install friction |

### Ops
| Category | Technology | Version | Justification |
|---|---|---|---|
| CI/CD | GitHub Actions | n/a | Native to GitHub repo; macOS runners for Xcode builds |
| Code signing | Apple `codesign` + Developer ID | n/a | Hardened runtime + timestamp |
| Notarization | `xcrun notarytool` | latest | App-specific password auth, stapling via `xcrun stapler` |
| Updates | Sparkle 2 `sign_update` | bundled in Sparkle | EdDSA appcast signing |
| Distribution | Homebrew tap | n/a | Cask = .app; Formula = Python daemon w/ 40 PyPI resource blocks |
| Daemon manager | macOS launchd via `launchctl` + `.plist` templates | system | KeepAlive; user-domain (no sudo needed) |
| DMG | `create-dmg` brew | latest | Background image + drag-to-Applications layout |
| Legacy hotkeys | Hammerspoon (Lua) | system install | Pre-Swift v1 path, kept side-by-side |

## Key Features

- **Speak any selection** — select text in any app, press hotkey
  (default `⌘⌥⇧S`), listen.
- **Read Chrome articles** — one hotkey (`⌘⌥⇧R`) reads the current
  page's main article (trafilatura extraction).
- **Claude Code on your terms** — parallel CC sessions announce
  themselves silently into the menu bar; user clicks which one to
  hear (full or summary). They never all talk at once.
- **Full or summary** — separate hotkey for summary (`⌘⌥⇧A`); summary
  runs locally via Ollama qwen3.5:4b. Summary mode is optional —
  Myna installs without Ollama.
- **Controls** — pause / resume / stop / speed from the menu bar or
  hotkeys. Speed adjustment uses AVAudioEngine's TimePitch unit —
  no pitch shift.
- **Real seek ±15s** — even across multi-chunk synthesized streams,
  via the virtual `PlaybackQueue` timeline.
- **Recordable hotkeys** — every action is rebindable from the
  Settings → Hotkeys tab; backed by `sindresorhus/KeyboardShortcuts`.
- **Sparkle 2 auto-updates** — EdDSA-signed, daily check.
- **Privacy** — no API calls except feedback the user chooses to send,
  no telemetry, no third-party SDK.
  Loopback-only. Signed + notarized so Gatekeeper trusts the binary.
- **Roadmap commitment** — open Windows decision rule (build at 100
  reactions on issue #1; close at <30 after 90 days).

## Architecture Highlights

- **Five parts, one repo.** Per-deliverable layout makes each part
  independently shippable (cask for the app, formula for the daemon,
  Vercel deploy for the site, GitHub Release for the DMG, brew tap
  for both).
- **Loopback-only HTTP between parts.** No serialization framework
  weirdness, no shared memory, no IPC magic. Easy to curl, easy to
  test, easy to stub.
- **Strict concurrency Swift app with an actor-based network client.**
  Sendable enforcement across the whole app; URLSession wrapped in a
  `DaemonClient` actor.
- **Multipart streaming for synthesize.** Avoids buffering the entire
  WAV before playback; first chunk plays within ~500 ms of POST.
  Custom multipart parser in Swift handles partial-boundary network
  reads (tested at 1-byte-per-read fragmentation).
- **Virtual timeline `PlaybackQueue`.** Decouples user-facing position
  from chunk boundaries so seek ±15 s, scrubbing, and pause/resume
  work consistently across a stream of N WAV chunks.
- **AVAudioEngine + TimePitch graph.** Speed-up without pitch shift,
  in real time.
- **Sparkle bottom-up framework signing.** The release pipeline signs
  Sparkle.framework helpers first (`Versions/B/*`), then
  `Versions/B`, then the framework root — matching Apple's versioned-
  framework spec exactly. Discovered after 10 release iterations that
  `actions/upload-artifact@v4` flattens symlinks and strips xattrs,
  breaking Sealed Resources V2 hashes mid-pipeline. Fix:
  **tar the .app between every job**. See
  [HANDOFF.md "The actual root cause"](https://github.com/PrerakGada/myna/blob/f5860c8/HANDOFF.md) for the
  full saga.
- **Homebrew tap formula generates 40 PyPI resource blocks** at
  release time + declares `depends_on "rust" => :build` so
  `pydantic_core` (maturin) and `watchfiles` (Rust) bootstrap from
  source on user installs. Trade-off: 20–30 min first install on a
  clean Mac; bottle-cached thereafter.
- **No CONTRIBUTING.md in repo root yet.** A
  [`contribution-guide.md`](./contribution-guide.md) was synthesized
  from existing evidence (`.swift-format`, `.swiftlint.yml`, recent
  commit messages, etc.) during this scan.

## Development Overview

### Prerequisites
- **macOS 13+ on Apple Silicon** (M1/M2/M3/M4).
- **Xcode 16+** for the Swift app.
- **XcodeGen** (`brew install xcodegen`) — `project.yml` → `Myna.xcodeproj`.
- **Python 3.13** at `~/.local/bin/python3.13` (LaunchAgent uses this
  exact path).
- **mlx-audio venv** at `~/.venvs/mlx-audio` with Kokoro cached.
- **Hammerspoon** (legacy menu-bar/hotkey path) — optional once the
  Swift app is running.
- **Ollama** with `qwen3.5:4b` — required only for summary mode.
- **Node 18+** for the marketing site.

### Getting Started

**End-user (install from brew):**
```bash
brew tap PrerakGada/tap
brew install --cask myna
open /Applications/Myna.app
```
First install ≈ 20–30 min (Python daemon compiles from source);
subsequent installs are bottle-cached.

**Contributor (local dev):**
```bash
git clone https://github.com/PrerakGada/myna.git ~/Developer/myna
cd ~/Developer/myna
./install.sh
```
Then in [`apps/macos/`](../apps/macos/): `bash dev.sh` runs xcodegen +
xcodebuild + open.

### Key Commands

#### macos
- **Bootstrap:** `cd apps/macos && xcodegen generate`
- **Dev loop:** `bash dev.sh` (xcodegen + build + open)
- **Test:** `xcodebuild test -scheme Myna -destination 'platform=macOS' -derivedDataPath build`
- **Lint:** `swiftlint && swift-format lint -r Sources Tests`

#### daemon
- **Install:** `~/.venvs/myna/bin/pip install -e daemon/`
- **Run:** `~/.venvs/myna/bin/python -m myna` (or via LaunchAgent)
- **Test:** `cd daemon && pytest` (94 tests)

#### site
- **Install:** `cd site && npm install`
- **Dev:** `npm run dev`
- **Build:** `npm run build`
- **Typecheck:** `npm run typecheck`

#### Ops — release
- **Per release:** bump `MARKETING_VERSION` in `apps/macos/project.yml`,
  commit, `git tag v0.X.Y && git push --tags`. GitHub Actions
  takes 10–20 min end-to-end. See
  [deployment-guide.md](./deployment-guide.md).
- **Smoke-test scripts locally:** `bash dist/tests/test_scripts.sh`

## Repository Structure

5 top-level deliverables + ops directories:

```
myna/
├── apps/macos/      → macos part (Swift app)
├── daemon/          → daemon part (FastAPI brain)
├── site/            → site part (Next.js marketing site)
├── cli/             → cli part (bash wrapper)
├── dist/            → ops: release shell scripts
├── tap/             → ops: Homebrew tap source
├── .github/         → ops: CI/CD workflows
├── launchagents/    → ops: LaunchAgent plist templates
├── hooks/           → ops: Claude Code Stop hook
├── hammerspoon/     → ops: v1 legacy menu bar + hotkeys
├── install.sh       → ops: local-dev installer
└── docs/            → generated + curated docs (this directory)
```

For the annotated full tree, see
[source-tree-analysis.md](./source-tree-analysis.md). For the
machine-readable parts manifest, see
[project-parts.json](./project-parts.json).

## Documentation Map

| Document | Purpose |
|---|---|
| [index.md](./index.md) | Master documentation index — start here |
| [project-overview.md](./project-overview.md) | This file |
| [source-tree-analysis.md](./source-tree-analysis.md) | Annotated directory tree + critical folders |
| [integration-architecture.md](./integration-architecture.md) | How parts integrate; sequence diagrams; failure modes |
| [risks-and-premortem.md](./risks-and-premortem.md) | Advanced-elicitation pass: pre-mortem, devil's advocate, red team |
| [architecture-macos.md](./architecture-macos.md) | Swift app deep dive |
| [architecture-daemon.md](./architecture-daemon.md) | Python daemon deep dive |
| [architecture-site.md](./architecture-site.md) | Next.js site deep dive |
| [architecture-ops.md](./architecture-ops.md) | Release pipeline + install + legacy + LaunchAgents deep dive |
| [component-inventory-macos.md](./component-inventory-macos.md) | Every Swift type with public API surface |
| [component-inventory-site.md](./component-inventory-site.md) | Every site .tsx with props + usages |
| [api-contracts-daemon.md](./api-contracts-daemon.md) | Daemon v1+v2 endpoint catalog + spec drift report |
| [data-models-daemon.md](./data-models-daemon.md) | Every Pydantic model + config schemas |
| [development-guide-macos.md](./development-guide-macos.md) | Swift app dev workflow |
| [development-guide-daemon.md](./development-guide-daemon.md) | Daemon dev workflow |
| [development-guide-site.md](./development-guide-site.md) | Site dev workflow |
| [development-guide-ops.md](./development-guide-ops.md) | Release-pipeline / scripts dev workflow |
| [deployment-guide.md](./deployment-guide.md) | Per-release operator commands (complements RELEASE.md) |
| [contribution-guide.md](./contribution-guide.md) | Code style + branch policy + PR process |
| [project-parts.json](./project-parts.json) | Machine-readable parts metadata |
| [project-scan-report.json](./project-scan-report.json) | Workflow state file |

---

_Generated using BMAD Method `document-project` workflow (exhaustive scan)._
