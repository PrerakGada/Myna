"""GET /v2/formats (the probe) and POST /v2/transcode."""

import shutil as real_shutil
import wave
import io

import pytest

from myna import encode
from .render_helpers import make_wav, render_client


@pytest.fixture(autouse=True)
def _fresh_probe():
    encode.reset_probe()
    yield
    encode.reset_probe()


def _only(tools):
    """shutil.which that finds exactly these tool names."""
    def which(name, path=None):
        return f"/fake/bin/{name}" if name in tools else None
    return which


def _formats(client):
    return {f["id"]: f for f in client.get("/v2/formats").json()["formats"]}


def test_formats_dmg_mac_has_afconvert_only(tmp_path, monkeypatch):
    monkeypatch.setattr(encode.shutil, "which", _only({"afconvert"}))
    client, _, _ = render_client(tmp_path)
    f = _formats(client)
    assert [x for x in f] == ["wav", "m4a", "mp3", "aac", "flac", "opus", "pcm"]
    for fid in ("wav", "pcm", "m4a", "aac", "flac"):
        assert f[fid]["available"] is True, fid
        assert "reason" not in f[fid]
    assert f["mp3"] == {"id": "mp3", "label": "MP3", "available": False, "ext": "mp3",
                        "mime": "audio/mpeg", "reason": "needs ffmpeg or lame"}
    assert f["opus"]["available"] is False
    assert f["opus"]["reason"] == "needs ffmpeg with libopus"
    assert f["m4a"]["mime"] == "audio/mp4"


def test_formats_lame_alone_gives_mp3(tmp_path, monkeypatch):
    monkeypatch.setattr(encode.shutil, "which", _only({"afconvert", "lame"}))
    client, _, _ = render_client(tmp_path)
    f = _formats(client)
    assert f["mp3"]["available"] is True
    assert f["opus"]["available"] is False


def test_formats_ffmpeg_needs_the_right_encoders(tmp_path, monkeypatch):
    monkeypatch.setattr(encode.shutil, "which", _only({"afconvert", "ffmpeg"}))
    monkeypatch.setattr(encode, "_ffmpeg_encoders", lambda path: " A..... libmp3lame  MP3\n")
    client, _, _ = render_client(tmp_path)
    f = _formats(client)
    assert f["mp3"]["available"] is True
    assert f["opus"]["available"] is False  # this ffmpeg has no libopus

    encode.reset_probe()
    monkeypatch.setattr(encode, "_ffmpeg_encoders", lambda path: " A..... libmp3lame\n A..... libopus\n")
    f = _formats(client)
    assert f["mp3"]["available"] and f["opus"]["available"]


def test_formats_nothing_installed_still_has_wav_and_pcm(tmp_path, monkeypatch):
    monkeypatch.setattr(encode.shutil, "which", lambda name, path=None: None)
    client, _, _ = render_client(tmp_path)
    f = _formats(client)
    assert f["wav"]["available"] and f["pcm"]["available"]
    assert not f["m4a"]["available"]
    assert f["m4a"]["reason"] == "needs /usr/bin/afconvert"


def test_transcode_to_pcm_and_wav(tmp_path):
    client, _, _ = render_client(tmp_path)
    wav = make_wav(2400)
    r = client.post("/v2/transcode?format=pcm", content=wav, headers={"Content-Type": "audio/wav"})
    assert r.status_code == 200
    assert len(r.content) == 4800
    r = client.post("/v2/transcode?format=wav", content=wav, headers={"Content-Type": "audio/wav"})
    assert r.status_code == 200
    assert r.content == wav


def test_transcode_rejects_non_wav_and_unknown_formats(tmp_path):
    client, _, _ = render_client(tmp_path)
    r = client.post("/v2/transcode?format=m4a", content=b"not audio at all, clearly not a wav file!!")
    assert r.status_code == 400
    assert r.json() == {"ok": False, "reason": "invalid_audio", "detail": "Send the audio as a WAV file (audio/wav)."}
    r = client.post("/v2/transcode?format=wma", content=make_wav(10))
    assert r.status_code == 400
    assert r.json()["reason"] == "invalid_format"


def test_transcode_unavailable_format(tmp_path, monkeypatch):
    monkeypatch.setattr(encode.shutil, "which", _only({"afconvert"}))
    client, _, _ = render_client(tmp_path)
    r = client.post("/v2/transcode?format=mp3", content=make_wav(100))
    assert r.status_code == 400
    assert r.json()["reason"] == "format_unavailable"


# Real encoders, when this Mac has them (it's macOS: afconvert always is).

needs_afconvert = pytest.mark.skipif(real_shutil.which("afconvert") is None, reason="no afconvert")


@needs_afconvert
@pytest.mark.parametrize("fmt, magic", [("m4a", b"ftyp"), ("flac", b"fLaC"), ("aac", b"\xff")])
def test_transcode_real_afconvert(tmp_path, fmt, magic):
    client, _, _ = render_client(tmp_path)
    r = client.post(f"/v2/transcode?format={fmt}", content=make_wav(24_000))
    assert r.status_code == 200, r.text
    assert magic in r.content[:12]
    assert r.headers["content-type"] == encode.FORMATS[fmt].mime


@pytest.mark.skipif(encode.find_tool("ffmpeg") is None and encode.find_tool("lame") is None, reason="no mp3 encoder")
def test_transcode_real_mp3(tmp_path):
    client, _, _ = render_client(tmp_path)
    r = client.post("/v2/transcode?format=mp3", content=make_wav(24_000))
    assert r.status_code == 200, r.text
    assert r.content[:3] == b"ID3" or r.content[0] == 0xFF


def test_encode_file_pcm_roundtrip(tmp_path):
    src = tmp_path / "in.wav"
    src.write_bytes(make_wav(480, value=7))
    out = tmp_path / "out.pcm"
    encode.encode_file(src, "pcm", out)
    with wave.open(io.BytesIO(src.read_bytes())) as w:
        assert out.read_bytes() == w.readframes(w.getnframes())
