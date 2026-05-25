"""Tests for POST /v2/extract."""

import json

from .v2_helpers import FIXTURES_DIR, make_client


def test_v2_extract_returns_text():
    client, fp, app = make_client()
    app.state.extract = lambda url: "EXTRACTED"
    r = client.post(
        "/v2/extract", json={"url": "https://example.com/article"}
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["text"] == "EXTRACTED"


def test_v2_extract_returns_title_and_byline_when_extract_provides_them():
    fixture = json.loads((FIXTURES_DIR / "extract-response.json").read_text())
    client, fp, app = make_client()

    def fake_extract(url):
        return {
            "text": fixture["text"],
            "title": fixture["title"],
            "byline": fixture["byline"],
        }

    app.state.extract = fake_extract
    r = client.post(
        "/v2/extract", json={"url": "https://example.com/lorem"}
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["text"] == fixture["text"]
    assert body["title"] == fixture["title"]
    assert body["byline"] == fixture["byline"]


def test_v2_extract_response_shape_matches_fixture():
    fixture = json.loads((FIXTURES_DIR / "extract-response.json").read_text())
    client, fp, app = make_client()
    app.state.extract = lambda url: {
        "text": fixture["text"],
        "title": fixture["title"],
        "byline": fixture["byline"],
    }
    r = client.post(
        "/v2/extract", json={"url": "https://example.com/lorem"}
    )
    body = r.json()
    # Every fixture key is present in the response.
    for k in fixture:
        assert k in body, f"missing key: {k}"


def test_v2_extract_failure_returns_not_ok():
    client, fp, app = make_client()
    app.state.extract = lambda url: None
    r = client.post(
        "/v2/extract", json={"url": "https://example.com/dead"}
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body["reason"] == "extract_failed"


def test_v2_extract_url_validation_rejects_non_http():
    client, fp, app = make_client()
    r = client.post("/v2/extract", json={"url": "file:///etc/passwd"})
    assert r.status_code == 400
    detail = r.json().get("detail", r.json())
    assert detail["reason"] == "invalid_url"


def test_v2_extract_url_validation_rejects_myna_scheme():
    client, fp, app = make_client()
    r = client.post("/v2/extract", json={"url": "myna://speak-selection"})
    assert r.status_code == 400


def test_v2_extract_passes_url_through_unchanged():
    seen = {}

    def fake_extract(url):
        seen["url"] = url
        return "OK"

    client, fp, app = make_client()
    app.state.extract = fake_extract
    client.post(
        "/v2/extract", json={"url": "https://example.com/article?id=42"}
    )
    assert seen["url"] == "https://example.com/article?id=42"
