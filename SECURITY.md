# Security Policy

Myna is a local-only macOS application. It does not send your text or audio to any third-party server. Your selections are transmitted only over `127.0.0.1` to a local daemon and a local Kokoro-82M TTS engine, both of which run on your machine.

## Threat model

Myna requires two macOS permissions that are sensitive:

1. **Accessibility** — needed to simulate `⌘C` so it can read your current text selection.
2. **Automation (AppleScript)** — needed to read the URL of your active Chrome tab.

Once granted, a malicious copy of Myna (or a compromised update) could simulate arbitrary keystrokes or read your active tab URLs. We mitigate this with:

- Code signing with a Developer ID Application certificate
- Apple notarization (Gatekeeper verification on every launch)
- Sparkle EdDSA-signed updates (only updates signed by our key install)
- All releases produced by GitHub Actions from public source

## Reporting a vulnerability

If you find a security issue, please **do not** open a public GitHub issue. Instead, email:

**rashid@dpsca.in** with subject `myna-security`

Or use GitHub's private vulnerability reporting on this repo.

Please include:
- A description of the issue
- Steps to reproduce
- The Myna version (`Myna → About`) and macOS version
- Whether you'd like credit in the release notes when fixed

We aim to acknowledge within 72 hours and ship a fix within 30 days for high-severity issues. Lower-severity issues land in the next scheduled release.

## Supported versions

Only the latest minor version receives security updates. Older versions should auto-update via Sparkle; if you've disabled auto-updates, please upgrade manually.

| Version | Supported |
|---|---|
| 0.x (pre-1.0) | Latest only |

## Disclosure

We follow coordinated disclosure: we'll work with you to fix the issue privately, then publish the fix and a CVE (when applicable) together.
