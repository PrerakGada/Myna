# frozen_string_literal: true

cask "myna" do
  version "0.1.0"
  sha256 :no_check # release.yml rewrites this with the real DMG sha256

  # No `verified:` — Homebrew 7 deprecates it and warns on every install; the
  # url already sits under the homepage, which is all the default check needs.
  url "https://github.com/PrerakGada/myna/releases/download/v#{version}/Myna-#{version}.dmg"
  name "Myna"
  desc "Always-on local TTS companion"
  homepage "https://github.com/PrerakGada/myna"

  # Defer to Sparkle for in-app updates instead of fighting it on every
  # `brew upgrade`. Users still get cask-driven upgrades when they explicitly
  # ask for them, but unattended `brew upgrade` won't replace the .app while
  # Sparkle is mid-download.
  auto_updates true
  depends_on macos: :sonoma # the voice engine needs macOS 14; setup.sh refuses older
  depends_on formula: "myna-daemon"

  app "Myna.app"

  zap trash: [
    "~/Library/Application Support/Myna",
    "~/Library/Caches/Myna",
    "~/Library/Logs/Myna",
    "~/Library/Preferences/dev.myna.app.plist",
    "~/Library/Saved Application State/dev.myna.app.savedState",
  ]
end
