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


# Word-break characters where it's natural to cut a long first sentence
# if it exceeds the max-words budget without ending naturally first. Order
# matters — we prefer harder phrase breaks over softer ones.
_FIRST_CHUNK_SOFT_BREAKS = (";", ":", " — ", ", ")


def _first_chunk_from_sentence(sentence: str, max_words: int) -> tuple[str, str]:
    """Cut ``sentence`` so the first piece is <= ``max_words`` words.

    Returns ``(first, remainder)``. If the sentence is already short enough,
    ``remainder`` is empty. If we have to cut, we prefer the rightmost soft
    break (`;`, `:`, ` — `, `, `) that falls within budget; otherwise we hard-
    cut at the word boundary.
    """
    words = sentence.split()
    if len(words) <= max_words:
        return sentence, ""

    # Hard-cut candidate at the max-words boundary; we'll only fall back to it
    # if no soft break is within budget.
    hard_cut = " ".join(words[:max_words])
    remainder_hard = " ".join(words[max_words:])

    # Look for a soft break within the hard_cut window — prefer the latest
    # one that still leaves us under budget, so the first chunk is as full as
    # it can naturally be.
    best_cut: tuple[str, str] | None = None
    for marker in _FIRST_CHUNK_SOFT_BREAKS:
        idx = hard_cut.rfind(marker)
        if idx <= 0:
            continue
        first = hard_cut[: idx + len(marker)].rstrip()
        # The remainder is everything after the marker in the ORIGINAL
        # sentence — using `hard_cut` would drop the rest of the sentence.
        original_idx = sentence.find(first)
        if original_idx < 0:
            continue
        rest = sentence[original_idx + len(first):].lstrip()
        if not rest:
            continue
        # Prefer the cut that gives the most words to the first piece (i.e.
        # the latest break) — this is the "fullest natural first sip" rule.
        if best_cut is None or len(first.split()) > len(best_cut[0].split()):
            best_cut = (first, rest)

    if best_cut is not None:
        return best_cut

    return hard_cut, remainder_hard


def chunk_text_with_priority_first(
    text: str,
    first_chunk_max_words: int = 15,
    rest_max_chars: int = 1500,
) -> list[str]:
    """Split text so the **first chunk is small** (fast time-to-first-audio)
    and subsequent chunks are sized for throughput.

    The first chunk is the first sentence; if that sentence is longer than
    ``first_chunk_max_words``, we cut at the rightmost soft break (`;`, `:`,
    ` — `, `, `) inside the word budget, or hard-cut at the word boundary if
    no soft break exists.

    The rest is chunked by :func:`chunk_text` with ``rest_max_chars``.

    Example::

        >>> chunks = chunk_text_with_priority_first(
        ...     "Hello world, this is a really long opening sentence "
        ...     "that runs on. The second sentence is here.",
        ...     first_chunk_max_words=8,
        ... )
        >>> chunks[0]
        'Hello world,'
        >>> len(chunks) >= 2
        True
    """
    text = text.strip()
    if not text:
        return []

    # Pull the first sentence off the front. Same regex as chunk_text uses
    # for splitting, applied only at the first hit so the rest stays intact.
    match = re.search(r"[.!?](?:\s+|$)", text)
    if match:
        first_sentence = text[: match.end()].rstrip()
        rest = text[match.end():].lstrip()
    else:
        # No sentence terminator at all — treat the whole text as one sentence.
        first_sentence = text
        rest = ""

    first_chunk, leftover = _first_chunk_from_sentence(
        first_sentence, first_chunk_max_words
    )
    # The leftover from cutting a long first sentence belongs at the head of
    # the remainder.
    if leftover:
        rest = f"{leftover} {rest}".strip() if rest else leftover

    chunks = [first_chunk]
    if rest:
        chunks.extend(chunk_text(rest, max_chars=rest_max_chars))
    return chunks
