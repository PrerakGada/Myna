/**
 * Every "Download" button points here. api.prerakgada.in counts the download
 * (cookieless, deduped per connection per day) and 302s to Myna.dmg on the
 * newest GitHub release, so the link never goes stale. /download on this site
 * redirects to the same place for links shared elsewhere.
 */
export const DOWNLOAD_URL = "https://api.prerakgada.in/d/myna/mac";

/**
 * The Homebrew install, one command per line. The page never prints these:
 * they ride on the tracker tag as data-command (app/layout.tsx), and the shared
 * download form shows them after it is filled in or skipped, the same way a
 * Download click is asked once. The only other places they appear are the
 * <noscript> fallback and HomebrewButton's inline reveal when the tracker
 * script never loaded (blocked or offline), so the button is never dead.
 */
export const HOMEBREW_LINES = [
  "brew tap prerakgada/tap",
  "brew trust prerakgada/tap",
  "brew install --cask prerakgada/tap/myna",
] as const;

export const HOMEBREW_COMMAND = HOMEBREW_LINES.join("\n");
