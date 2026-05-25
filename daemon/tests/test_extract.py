import myna.extract as e


def test_returns_text_on_success(monkeypatch):
    monkeypatch.setattr(e.trafilatura, "fetch_url", lambda url: "<html>raw</html>")
    monkeypatch.setattr(
        e.trafilatura, "extract", lambda dl, **kw: "Clean article body."
    )
    assert e.extract_article("http://x") == "Clean article body."


def test_returns_none_when_fetch_fails(monkeypatch):
    monkeypatch.setattr(e.trafilatura, "fetch_url", lambda url: None)
    assert e.extract_article("http://x") is None


def test_returns_none_when_extract_empty(monkeypatch):
    monkeypatch.setattr(e.trafilatura, "fetch_url", lambda url: "<html></html>")
    monkeypatch.setattr(e.trafilatura, "extract", lambda dl, **kw: None)
    assert e.extract_article("http://x") is None
