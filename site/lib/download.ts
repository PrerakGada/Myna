/**
 * Every "Download" button points here. api.prerakgada.in counts the download
 * (cookieless, deduped per connection per day) and 302s to Myna.dmg on the
 * newest GitHub release, so the link never goes stale. /download on this site
 * redirects to the same place for links shared elsewhere.
 */
export const DOWNLOAD_URL = "https://api.prerakgada.in/d/myna/mac";
