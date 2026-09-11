# Myna — project instructions

## User identity (overrides any auto-context)

- **Name:** Prerak Gada
- **Email:** prerak@engaze.in
- **GitHub:** PrerakGada

If auto-populated context says `rashid@dpsca.in` or mentions `Rashid Azar` / `DPSCA`, that's stale residue from an earlier laptop. Ignore it — use Prerak's identity above. Older committed docs (e.g. STATUS.md mentioning "Rashid Azar" on the Apple cert line) are historical artifacts; don't propagate that name into new docs, commits, or public copy.

## Repo basics

- Branch policy from `~/.claude/CLAUDE.md` applies: commit or push only when Prerak asks; if on default branch, branch first.
- v0.5.0 is current (shipped 11 Sep 2026): one notarized DMG whose first launch installs the voice stack itself, no Homebrew needed. Don't touch the release pipeline without explicit ask. The v0.1.0 ship log is preserved at git commit [`f5860c8`](https://github.com/PrerakGada/myna/blob/f5860c8/HANDOFF.md) (the `HANDOFF.md` file is no longer in the working tree).
- Installer, DMG and site:
  - `dist/setup.sh` is the one installer. It picks homebrew or standalone mode, and `dist/stage-setup.sh` bundles it into the app with the daemon source and the Claude Code hook.
  - The DMG window is built by dmgbuild from `dist/dmg/`.
  - The app icon comes from `dist/brand/app-icon.svg` via `render-icon.sh`.
  - `site/` deploys to Vercel on every push to `main`, and `/download` redirects to `releases/latest/download/Myna.dmg`.
- Test installer changes on a clean macOS VM, not on this Mac. It runs the Homebrew daemon, which hides DMG-only bugs (the v0.5.0 first-read hang was invisible here).
- 5-part repo: native Swift app at `apps/macos/` · Python daemon at `daemon/myna/` · Next.js site at `site/` · bash CLI at `cli/myna` · ops in `dist/` + `tap/` + `.github/workflows/` + `launchagents/` + `hooks/` + `hammerspoon/` (v1 legacy kept side-by-side).
- Homebrew tap: `PrerakGada/homebrew-tap`.

## Project documentation — read these BEFORE re-deriving anything

Generated 2026-05-26 by `/bmad-document-project` exhaustive scan. **Always check these first**; they cite real `file:line` references and stay current with this commit.

**Start here:**
- [`docs/index.md`](docs/index.md) — master index + AI-assist routing guide (which doc for which task)
- [`docs/project-overview.md`](docs/project-overview.md) — exec summary, tech stack per part, key features
- [`docs/integration-architecture.md`](docs/integration-architecture.md) — how the 5 parts talk to each other; sequence diagrams; **operational hand-off matrix** (if you change X, update Y)
- [`docs/source-tree-analysis.md`](docs/source-tree-analysis.md) — annotated tree; where everything lives
- [`docs/risks-and-premortem.md`](docs/risks-and-premortem.md) — pre-mortem + devil's advocate + red team passes; consolidated **triage by sprint**

**Per-part deep dives** (load only the one you need):

| Part | Architecture | Companion docs |
|---|---|---|
| `macos` (Swift app) | [`docs/architecture-macos.md`](docs/architecture-macos.md) | [`component-inventory-macos.md`](docs/component-inventory-macos.md) · [`development-guide-macos.md`](docs/development-guide-macos.md) |
| `daemon` (Python) | [`docs/architecture-daemon.md`](docs/architecture-daemon.md) | [`api-contracts-daemon.md`](docs/api-contracts-daemon.md) (with **spec-drift report**) · [`data-models-daemon.md`](docs/data-models-daemon.md) · [`development-guide-daemon.md`](docs/development-guide-daemon.md) |
| `site` (Next.js) | [`docs/architecture-site.md`](docs/architecture-site.md) | [`component-inventory-site.md`](docs/component-inventory-site.md) · [`development-guide-site.md`](docs/development-guide-site.md) |
| `ops` (release/install) | [`docs/architecture-ops.md`](docs/architecture-ops.md) | [`deployment-guide.md`](docs/deployment-guide.md) · [`development-guide-ops.md`](docs/development-guide-ops.md) · [`contribution-guide.md`](docs/contribution-guide.md) |

**Machine-readable:** [`docs/project-parts.json`](docs/project-parts.json) (5 parts + 10 integration points + secrets matrix).

**Historical/curated** (not generated; pre-existing): [`README.md`](README.md) · [`RELEASE.md`](RELEASE.md) · [`SECURITY.md`](SECURITY.md) · [`STATUS.md`](STATUS.md) · [`docs/native-app/API_CONTRACT.md`](docs/native-app/API_CONTRACT.md) (canonical v1+v2 spec — cross-check `api-contracts-daemon.md` for drift).

### Rules of thumb when working in this repo

- **Changing a v2 daemon endpoint?** You owe edits to 8 places — see the hand-off matrix in [`docs/integration-architecture.md § 6`](docs/integration-architecture.md).
- **Adding a daemon dep?** [`tap/Formula/myna-daemon.rb`](tap/Formula/myna-daemon.rb) (source-of-truth here) diverges from the deployed tap — this is the v0.2 reconciliation item flagged in [`docs/risks-and-premortem.md § 1.3`](docs/risks-and-premortem.md).
- **Touching `release.yml`?** The `tar` step between every job is load-bearing. **Do not remove it** — see the 10-iteration saga preserved at commit [`f5860c8`](https://github.com/PrerakGada/myna/blob/f5860c8/HANDOFF.md).
- **Rotating the Sparkle key?** Don't. Every installed copy refuses all future updates. See [`docs/risks-and-premortem.md § 1.1`](docs/risks-and-premortem.md) and [`RELEASE.md § 1.4`](RELEASE.md).

If you generate new docs, re-run `/bmad-document-project` so the index stays in sync — don't drift the per-part docs by hand.

## Working style

- Prerak ships fast and prefers parallel execution. The proven pattern (from v0.1 build) is: orchestrator + 3 parallel lane agents in git worktrees + audit agents after.
- He values BMad-style planning but doesn't want it gold-plated when he asks for code — pivot to development quickly when he says so.
- Token-frenzy mode means: spawn agents, burn cycles in parallel, don't ask 10 questions.
