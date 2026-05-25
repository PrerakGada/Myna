import trafilatura


def extract_article(url: str) -> str | None:
    """Fetch a URL and return its main article text, or None if unavailable."""
    downloaded = trafilatura.fetch_url(url)
    if not downloaded:
        return None
    text = trafilatura.extract(
        downloaded, include_comments=False, include_tables=False
    )
    return text or None
