/**
 * The primary call to action. /download redirects to Myna.dmg on the newest
 * GitHub release (see next.config.mjs), so this link never goes stale.
 */
export function DownloadButton({ label = "Download for Mac", className }: { label?: string; className?: string }) {
  return (
    <a href="/download" className={`btn-primary ${className ?? ""}`}>
      <svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
        <path d="M11.2 8.5c0-1.6 1.3-2.4 1.4-2.5-.8-1.1-2-1.3-2.4-1.3-1-.1-2 .6-2.5.6-.5 0-1.3-.6-2.2-.6-1.1 0-2.2.7-2.7 1.7-1.2 2-.3 5 .8 6.6.6.8 1.2 1.7 2 1.6.8 0 1.1-.5 2.1-.5s1.2.5 2.1.5c.9 0 1.4-.8 1.9-1.6.6-.9.9-1.8.9-1.8s-1.4-.6-1.4-2.7ZM9.6 3.6c.4-.5.7-1.2.6-1.9-.6 0-1.4.4-1.8.9-.4.4-.7 1.1-.6 1.8.7.1 1.4-.3 1.8-.8Z" />
      </svg>
      <span>{label}</span>
    </a>
  );
}

/** The version of the newest release, for "Version x.y.z" labels. */
export async function getLatestVersion(): Promise<string | null> {
  try {
    const res = await fetch("https://api.github.com/repos/PrerakGada/Myna/releases/latest", {
      next: { revalidate: 1800 },
      headers: { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { tag_name?: string };
    return data.tag_name ? data.tag_name.replace(/^v/, "") : null;
  } catch {
    return null;
  }
}
