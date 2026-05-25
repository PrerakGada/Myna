# Myna.app (native macOS)

Swift menu bar app. Replaces the v1 Hammerspoon script with a native UI, a real audio engine (speed / seek / scrub), Sparkle auto-updates, and Homebrew Cask distribution.

See the [proposal](../../docs/native-app/NATIVE_APP_PROPOSAL.md), [API contract](../../docs/native-app/API_CONTRACT.md), and [test plan](../../docs/native-app/TEST_PLAN.md).

## Build

```bash
brew install xcodegen swiftlint swift-format
cd apps/macos
xcodegen generate
open Myna.xcodeproj
# or
xcodebuild -scheme Myna -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild test -scheme Myna -destination 'platform=macOS'
```

## Lint

```bash
swiftlint --strict
swift-format lint --recursive --strict Sources Tests
```

## Project layout

See `project.yml`. SPM packages are managed there, not in Xcode UI.
