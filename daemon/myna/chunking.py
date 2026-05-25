import re


def chunk_text(text: str, max_chars: int = 1500) -> list[str]:
    """Split text into <= max_chars chunks on sentence boundaries.

    A single sentence longer than max_chars is hard-split.
    """
    text = text.strip()
    if not text:
        return []
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunks: list[str] = []
    cur = ""
    for s in sentences:
        if not cur:
            cur = s
        elif len(cur) + 1 + len(s) <= max_chars:
            cur = f"{cur} {s}"
        else:
            chunks.append(cur)
            cur = s
        while len(cur) > max_chars:
            chunks.append(cur[:max_chars])
            cur = cur[max_chars:]
    if cur:
        chunks.append(cur)
    return chunks
