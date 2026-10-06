"""Audio encoders for finished renders: WAV in, the format someone asked for out.

The engine only ever hands the daemon 16-bit WAV. Everything else is a
conversion, and what this Mac can convert to depends on what is installed:

  * WAV and raw PCM need nothing but the stdlib.
  * AAC (in .m4a, or bare ADTS .aac) and FLAC use /usr/bin/afconvert, which
    ships with every Mac.
  * MP3 needs ffmpeg built with libmp3lame, or the `lame` CLI. Ogg Opus needs
    ffmpeg built with libopus. A Homebrew developer's Mac usually has both; a
    DMG user's usually has neither.

`probe()` reports exactly that, so `/v2/formats` never promises a format the
encode step then can't make. m4a chapter markers are written only when ffmpeg
is present (a stream-copy remux with an ffmetadata file); without it the job
still reports its chapters, the file just doesn't carry them.
"""

from __future__ import annotations

import dataclasses
import os
import shutil
import subprocess
import tempfile
import threading
import time
import wave
from pathlib import Path
from typing import Optional


@dataclasses.dataclass(frozen=True)
class FormatSpec:
    id: str
    label: str
    ext: str
    mime: str


# Order is the order the UI lists them in.
FORMATS: dict[str, FormatSpec] = {
    f.id: f
    for f in (
        FormatSpec("wav", "WAV", "wav", "audio/wav"),
        FormatSpec("m4a", "M4A (AAC)", "m4a", "audio/mp4"),
        FormatSpec("mp3", "MP3", "mp3", "audio/mpeg"),
        FormatSpec("aac", "AAC (ADTS)", "aac", "audio/aac"),
        FormatSpec("flac", "FLAC", "flac", "audio/flac"),
        FormatSpec("opus", "Ogg Opus", "opus", "audio/ogg"),
        FormatSpec("pcm", "PCM (raw 16-bit)", "pcm", "audio/L16"),
    )
}

# Speech-tuned bitrates for mono. A voice at these rates is indistinguishable
# from the WAV; music would want more.
_AAC_BPS = 64_000
_MP3_KBPS = 64
_OPUS_KBPS = 32

# launchd starts the standalone daemon with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
# so a Homebrew ffmpeg is invisible to a plain `which`. Look where Homebrew
# puts things too; whatever is found here is what encode() will run.
_EXTRA_TOOL_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")

_PROBE_TTL_S = 60.0


class FormatUnavailable(Exception):
    """This Mac can't produce the format. `str(exc)` says what's missing."""


class EncodeError(Exception):
    """The encoder ran and failed."""


@dataclasses.dataclass(frozen=True)
class Availability:
    available: bool
    tool: Optional[str] = None  # "stdlib", "afconvert", "ffmpeg" or "lame"
    reason: Optional[str] = None


def find_tool(name: str) -> Optional[str]:
    found = shutil.which(name)
    if found:
        return found
    return shutil.which(name, path=os.pathsep.join(_EXTRA_TOOL_DIRS))


def _ffmpeg_encoders(ffmpeg: str) -> str:
    try:
        out = subprocess.run(
            [ffmpeg, "-hide_banner", "-encoders"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout


class _Probe:
    """What this Mac can encode, re-checked at most once a minute so
    installing ffmpeg is noticed without restarting the daemon."""

    def __init__(self):
        self._lock = threading.Lock()
        self._at = 0.0
        self._result: dict[str, Availability] = {}
        self._tools: dict[str, Optional[str]] = {}

    def get(self) -> tuple[dict[str, Availability], dict[str, Optional[str]]]:
        with self._lock:
            if not self._result or time.monotonic() - self._at > _PROBE_TTL_S:
                self._result, self._tools = _probe_now()
                self._at = time.monotonic()
            return self._result, self._tools

    def reset(self) -> None:
        with self._lock:
            self._at = 0.0
            self._result = {}


def _probe_now() -> tuple[dict[str, Availability], dict[str, Optional[str]]]:
    afconvert = find_tool("afconvert")
    ffmpeg = find_tool("ffmpeg")
    lame = find_tool("lame")
    encoders = _ffmpeg_encoders(ffmpeg) if ffmpeg else ""
    ff_mp3 = bool(ffmpeg) and "libmp3lame" in encoders
    ff_opus = bool(ffmpeg) and "libopus" in encoders

    result = {
        "wav": Availability(True, "stdlib"),
        "pcm": Availability(True, "stdlib"),
    }
    for fid in ("m4a", "aac", "flac"):
        result[fid] = (
            Availability(True, "afconvert") if afconvert
            else Availability(False, reason="needs /usr/bin/afconvert")
        )
    if ff_mp3:
        result["mp3"] = Availability(True, "ffmpeg")
    elif lame:
        result["mp3"] = Availability(True, "lame")
    else:
        result["mp3"] = Availability(False, reason="needs ffmpeg or lame")
    result["opus"] = (
        Availability(True, "ffmpeg") if ff_opus
        else Availability(False, reason="needs ffmpeg with libopus")
    )
    tools = {"afconvert": afconvert, "ffmpeg": ffmpeg, "lame": lame}
    return result, tools


_probe = _Probe()


def probe() -> dict[str, Availability]:
    return _probe.get()[0]


def reset_probe() -> None:
    """Forget the cached probe (tests patch `shutil.which`)."""
    _probe.reset()


def formats_payload() -> list[dict]:
    avail = probe()
    out = []
    for spec in FORMATS.values():
        a = avail[spec.id]
        entry = {
            "id": spec.id,
            "label": spec.label,
            "available": a.available,
            "ext": spec.ext,
            "mime": spec.mime,
        }
        if not a.available:
            entry["reason"] = a.reason
        out.append(entry)
    return out


def require(fmt: str) -> FormatSpec:
    """The spec for `fmt`, or FormatUnavailable if this Mac can't make it.
    Raises KeyError for a format id Myna doesn't know at all."""
    spec = FORMATS[fmt]
    a = probe()[fmt]
    if not a.available:
        raise FormatUnavailable(f"This Mac can't encode {spec.label}: it {a.reason}.")
    return spec


# ----- encoding -----


def _run(cmd: list[str], timeout: float) -> None:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise EncodeError(f"{Path(cmd[0]).name} took longer than {int(timeout)} s") from None
    except OSError as exc:
        raise EncodeError(f"couldn't run {cmd[0]}: {exc}") from None
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-3:]
        raise EncodeError(f"{Path(cmd[0]).name} failed: {' '.join(tail)[:400]}")


def _wav_duration_s(wav_path: Path) -> float:
    try:
        with wave.open(str(wav_path), "rb") as w:
            return w.getnframes() / float(w.getframerate() or 1)
    except (wave.Error, EOFError, OSError):
        return 0.0


def _ffmetadata_escape(value: str) -> str:
    out = value
    for ch in ("\\", "=", ";", "#", "\n"):
        out = out.replace(ch, "\\" + ch)
    return out


def _write_ffmetadata(path: Path, chapters: list[dict], duration_s: float, title: Optional[str]) -> None:
    lines = [";FFMETADATA1"]
    if title:
        lines.append(f"title={_ffmetadata_escape(title)}")
    ends = [c["start_s"] for c in chapters[1:]] + [duration_s]
    for chapter, end in zip(chapters, ends):
        start_ms = int(round(chapter["start_s"] * 1000))
        end_ms = max(start_ms + 1, int(round(end * 1000)))
        lines += [
            "",
            "[CHAPTER]",
            "TIMEBASE=1/1000",
            f"START={start_ms}",
            f"END={end_ms}",
            f"title={_ffmetadata_escape(chapter['title'])}",
        ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def encode_file(
    wav_path: Path,
    fmt: str,
    out_path: Path,
    *,
    chapters: Optional[list[dict]] = None,
    title: Optional[str] = None,
) -> bool:
    """Encode the WAV at `wav_path` into `out_path` as `fmt`.

    Returns True when chapter markers were written into the file (m4a with
    ffmpeg present and more than one chapter), False otherwise. Raises
    FormatUnavailable or EncodeError.
    """
    require(fmt)
    _, tools = _probe.get()
    avail = probe()[fmt]
    wav_path = Path(wav_path)
    out_path = Path(out_path)
    # Generous but finite: a hung encoder must not wedge the render worker.
    timeout = 120.0 + _wav_duration_s(wav_path) / 2.0

    if fmt == "wav":
        shutil.copyfile(wav_path, out_path)
        return False
    if fmt == "pcm":
        with wave.open(str(wav_path), "rb") as w, open(out_path, "wb") as out:
            while True:
                frames = w.readframes(65536)
                if not frames:
                    break
                out.write(frames)
        return False
    if fmt in ("m4a", "aac", "flac"):
        afconvert = tools["afconvert"]
        if fmt == "flac":
            cmd = [afconvert, "-f", "flac", "-d", "flac", str(wav_path), str(out_path)]
        else:
            container = "m4af" if fmt == "m4a" else "adts"
            cmd = [afconvert, "-f", container, "-d", "aac", "-b", str(_AAC_BPS), str(wav_path), str(out_path)]
        _run(cmd, timeout)
        if fmt == "m4a" and chapters and len(chapters) > 1 and tools["ffmpeg"]:
            return _add_m4a_chapters(tools["ffmpeg"], out_path, chapters, _wav_duration_s(wav_path), title, timeout)
        return False
    if fmt == "mp3":
        if avail.tool == "ffmpeg":
            cmd = [
                tools["ffmpeg"], "-hide_banner", "-loglevel", "error", "-y", "-i", str(wav_path),
                "-c:a", "libmp3lame", "-b:a", f"{_MP3_KBPS}k", str(out_path),
            ]
        else:
            cmd = [tools["lame"], "--quiet", "-b", str(_MP3_KBPS), str(wav_path), str(out_path)]
        _run(cmd, timeout)
        return False
    if fmt == "opus":
        cmd = [
            tools["ffmpeg"], "-hide_banner", "-loglevel", "error", "-y", "-i", str(wav_path),
            "-c:a", "libopus", "-b:a", f"{_OPUS_KBPS}k", "-f", "ogg", str(out_path),
        ]
        _run(cmd, timeout)
        return False
    raise FormatUnavailable(f"unknown format {fmt}")


def _add_m4a_chapters(
    ffmpeg: str, m4a: Path, chapters: list[dict], duration_s: float, title: Optional[str], timeout: float
) -> bool:
    """Stream-copy `m4a` with chapter markers. The audio isn't re-encoded.
    On any failure the chapterless file is kept and False is returned."""
    meta = m4a.with_suffix(".ffmeta")
    tmp = m4a.with_name(m4a.stem + ".chapters.m4a")
    try:
        _write_ffmetadata(meta, chapters, duration_s, title)
        _run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                "-i", str(m4a), "-f", "ffmetadata", "-i", str(meta),
                "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1",
                "-c", "copy", "-movflags", "+faststart", str(tmp),
            ],
            timeout,
        )
        tmp.replace(m4a)
        return True
    except EncodeError:
        return False
    finally:
        meta.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)


def encode_bytes(wav: bytes, fmt: str) -> bytes:
    """Encode an in-memory WAV. For the synchronous paths (/v1/audio/speech,
    /v2/transcode); render jobs encode files on disk."""
    if fmt == "wav":
        require(fmt)
        return wav
    with tempfile.TemporaryDirectory(prefix="myna-encode-") as d:
        src = Path(d) / "in.wav"
        dst = Path(d) / f"out.{FORMATS[fmt].ext}"
        src.write_bytes(wav)
        encode_file(src, fmt, dst)
        return dst.read_bytes()
