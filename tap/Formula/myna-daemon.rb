# frozen_string_literal: true

# Myna's Python HTTP daemon — chunking, extract, summarize, /synthesize.
# Installed via Homebrew so the .app cask can depend on it.
class MynaDaemon < Formula
  include Language::Python::Virtualenv

  desc "Myna's Python HTTP daemon (chunking, extract, summarize, /synthesize)"
  homepage "https://github.com/CHANGEME/myna"
  url "https://github.com/CHANGEME/myna/archive/refs/tags/v0.1.0.tar.gz"
  # release.yml does NOT bump this formula on every release — it bumps the cask
  # only. Daemon updates ride the cask's homepage release; bump this manually
  # when daemon code changes meaningfully.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/CHANGEME/myna.git", branch: "main"

  depends_on "python@3.13"

  # The daemon needs an mlx-audio Kokoro engine on :8765. That engine is too
  # heavy to bundle via brew (multi-GB model weights, Apple-Silicon-only). We
  # document the engine install in `brew info` caveats below and skip it as a
  # dependency.

  def install
    # The repo is laid out as a monorepo; daemon/ holds the Python package.
    cd "daemon" do
      virtualenv_install_with_resources
    end

    # Convenience symlink so users can run `myna-daemon` (matches the LaunchAgent).
    (bin/"myna-daemon").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" -m myna "$@"
    SH
    chmod 0755, bin/"myna-daemon"

    # Default config (only written if not present — install logic mirrors install.sh).
    (etc/"myna").mkpath
    keybindings = etc/"myna/keybindings.json"
    return if keybindings.exist?

    keybindings.write <<~JSON
      {
        "speak_selection_full":    { "mods": ["cmd","alt","shift"], "key": "s" },
        "speak_selection_summary": { "mods": ["cmd","alt","shift"], "key": "a" },
        "read_chrome_article":     { "mods": ["cmd","alt","shift"], "key": "r" },
        "pause_resume":            { "mods": ["cmd","alt","shift"], "key": "space" },
        "stop":                    { "mods": ["cmd","alt","shift"], "key": "." }
      }
    JSON
  end

  # Auto-managed LaunchAgent via Homebrew's `brew services` interface. Users
  # can `brew services start myna-daemon` once and forget.
  service do
    run [opt_bin/"myna-daemon"]
    keep_alive true
    log_path   var/"log/myna-daemon.log"
    error_log_path var/"log/myna-daemon.log"
    working_dir var/"myna"
    environment_variables MYNA_CONFIG_DIR: etc/"myna"
  end

  def caveats
    <<~EOS
      Myna's daemon is now installed.

      Start it (and have it relaunch on boot) with:
        brew services start myna-daemon

      The daemon expects an mlx-audio Kokoro TTS engine on http://127.0.0.1:8765.
      That engine is too heavy to bundle via brew. Install it yourself with:

        python3.13 -m venv ~/.venvs/mlx-audio
        ~/.venvs/mlx-audio/bin/pip install mlx-audio

      Then run the engine (or wrap it in your own LaunchAgent):
        ~/.venvs/mlx-audio/bin/python -m mlx_audio.server --port 8765

      Config lives in #{etc}/myna/.
      Logs:     #{var}/log/myna-daemon.log
    EOS
  end

  test do
    # The package exposes a `myna` console-script that responds to --help.
    assert_match "usage", shell_output("#{bin}/myna-daemon --help 2>&1")
  end
end
