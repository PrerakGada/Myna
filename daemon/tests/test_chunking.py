from myna.chunking import chunk_text


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
