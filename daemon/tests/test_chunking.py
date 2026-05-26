from myna.chunking import chunk_text, chunk_text_with_priority_first


def test_empty_returns_no_chunks():
    assert chunk_text("") == []
    assert chunk_text("   ") == []


def test_short_text_is_single_chunk():
    assert chunk_text("Hello world.") == ["Hello world."]


def test_packs_sentences_under_limit():
    text = "One. Two. Three. Four."
    chunks = chunk_text(text, max_chars=10)
    assert all(len(c) <= 10 for c in chunks)
    assert " ".join(chunks).replace("  ", " ").count("One.") == 1
    assert len(chunks) > 1


def test_hard_splits_oversized_sentence():
    long = "x" * 25
    chunks = chunk_text(long, max_chars=10)
    assert all(len(c) <= 10 for c in chunks)
    assert "".join(chunks) == long


# ---------- priority-first chunking (TTFA + rolling buffer) ----------


def test_priority_first_empty_returns_empty():
    assert chunk_text_with_priority_first("") == []
    assert chunk_text_with_priority_first("   ") == []


def test_priority_first_short_text_one_chunk():
    """A short single sentence fits entirely in the first chunk; no rest."""
    chunks = chunk_text_with_priority_first("Hello world.", first_chunk_max_words=15)
    assert chunks == ["Hello world."]


def test_priority_first_first_sentence_fits_under_budget():
    """First sentence (<= max_words) becomes the first chunk verbatim; the
    remaining text is chunked normally afterwards."""
    text = "Hello world. The rest of the text comes later and is longer."
    chunks = chunk_text_with_priority_first(text, first_chunk_max_words=15)
    assert chunks[0] == "Hello world."
    assert len(chunks) >= 2
    assert "The rest of the text" in " ".join(chunks[1:])


def test_priority_first_caps_long_first_sentence():
    """A long first sentence is cut at the word budget."""
    text = (
        "This is a really long opening sentence that runs on for many words "
        "and would otherwise dominate the time-to-first-audio. Second sentence."
    )
    chunks = chunk_text_with_priority_first(text, first_chunk_max_words=8)
    assert len(chunks[0].split()) <= 8
    combined = " ".join(chunks)
    assert "Second sentence." in combined
    assert "would otherwise dominate" in combined


def test_priority_first_prefers_soft_break_within_budget():
    """When a comma falls within the word budget, the cut happens at the comma
    rather than mid-phrase (more natural to listen to)."""
    text = "Hello there, this is the opening sentence that is way too long."
    chunks = chunk_text_with_priority_first(text, first_chunk_max_words=8)
    assert chunks[0].rstrip().endswith((",", ";", ":"))
    assert len(chunks) >= 2


def test_priority_first_hard_cuts_when_no_soft_break():
    """If there's no comma/semicolon inside the word budget, hard-cut at the
    word boundary."""
    text = ("Word " * 30).strip()  # 30 single-word units, no punctuation
    chunks = chunk_text_with_priority_first(text, first_chunk_max_words=10)
    assert len(chunks[0].split()) == 10
    total_words = sum(len(c.split()) for c in chunks)
    assert total_words == 30


def test_priority_first_rest_chunked_by_max_chars():
    """The remainder is chunked by `rest_max_chars`, not by word count."""
    rest = "Filler sentence. " * 200  # very long remainder
    text = "Short opener. " + rest
    chunks = chunk_text_with_priority_first(
        text, first_chunk_max_words=15, rest_max_chars=200
    )
    assert chunks[0] == "Short opener."
    for c in chunks[1:]:
        assert len(c) <= 250  # max_chars + sentence-boundary slack


def test_priority_first_handles_no_terminator():
    """Text with no `.!?` at all is treated as one sentence."""
    text = "no terminator here just words"
    chunks = chunk_text_with_priority_first(text, first_chunk_max_words=15)
    assert chunks == [text]


def test_priority_first_round_trip_preserves_words():
    """Joining all chunks back together preserves the original word set."""
    text = (
        "Quick first sentence. Then a longer second one with several words. "
        "And a third sentence to round it out."
    )
    chunks = chunk_text_with_priority_first(text, first_chunk_max_words=15)
    original_words = set(text.replace(".", "").split())
    joined_words = set(" ".join(chunks).replace(".", "").split())
    assert original_words == joined_words
