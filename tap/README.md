# Myna — Homebrew tap

This directory is the **source of truth** for Myna's Homebrew tap. The release
workflow (`.github/workflows/release.yml`) mirrors `Casks/myna.rb` into the
`homebrew-myna` tap repository on every release tag (after rewriting the
`version` and `sha256` lines).

## Installing Myna

```bash
brew tap rashid/myna           # adds the tap (repo: github.com/rashid/homebrew-myna)
brew install --cask myna       # installs Myna.app + the daemon as a dep
brew services start myna-daemon
```

After install:

1. Launch Myna.app from `/Applications`.
2. On first hotkey use, grant Accessibility and (if you use the Chrome hotkey) Automation permissions.
3. Hotkeys default to ⌘⌥⇧S / ⌘⌥⇧A / ⌘⌥⇧R / ⌘⌥⇧Space / ⌘⌥⇧.

## Upgrading

```bash
brew upgrade --cask myna       # explicit user-driven upgrade
brew services restart myna-daemon
```

Sparkle handles silent in-app upgrades automatically; the cask defers to
Sparkle via `auto_updates true` so the two don't fight.

## Uninstalling

```bash
brew uninstall --cask --zap myna   # `--zap` also removes ~/Library data
brew uninstall myna-daemon
brew services stop myna-daemon || true
```

## Contents

| File | What |
|---|---|
| `Casks/myna.rb`         | Cask that installs `Myna.app` from the GitHub Release DMG |
| `Formula/myna-daemon.rb` | Formula that installs the Python daemon and a `brew services` LaunchAgent |

## How the cask version + sha256 stay in sync

`release.yml`'s `tap-bump` job:

1. Computes `sha256` of the signed DMG.
2. Checks out the `homebrew-myna` tap repo with `TAP_DEPLOY_KEY`.
3. `sed`s the new `version "X.Y.Z"` and `sha256 "…"` into `Casks/myna.rb`.
4. Commits with message `myna X.Y.Z` and pushes.

`Formula/myna-daemon.rb` is **not** bumped automatically — daemon updates ride
the cask's release tag. Bump it manually in this repo when daemon code changes
meaningfully (then re-tag a release).

## Mirroring this directory into the real tap repo

The first time you set up the tap, manually copy these files to your
`homebrew-myna` repo:

```bash
gh repo create rashid/homebrew-myna --public
git clone git@github.com:rashid/homebrew-myna.git ~/Developer/homebrew-myna
cp -R tap/Casks tap/Formula ~/Developer/homebrew-myna/
cd ~/Developer/homebrew-myna && git add -A && git commit -m 'initial' && git push
```

After that, `release.yml`'s `tap-bump` job keeps it in sync.
