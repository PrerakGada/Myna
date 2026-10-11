import hashlib

import httpx


def synthesize(
    text: str,
    *,
    voice: str,
    speed: float,
    base_url: str,
    model: str = "prince-canuma/Kokoro-82M",
    lang_code: str = "a",
    timeout: float = 180.0,
    extra: dict | None = None,
) -> bytes:
    # `extra` carries an engine's own sampling settings (myna.engines). The
    # mlx-audio server substitutes its generic defaults for anything omitted.
    body = {
        "model": model,
        "input": text,
        "voice": voice,
        "response_format": "wav",
        "lang_code": lang_code,
        "speed": speed,
    }
    if extra:
        body.update(extra)
    resp = httpx.post(f"{base_url}/v1/audio/speech", json=body, timeout=timeout)
    resp.raise_for_status()
    return resp.content


def word_timings_key(text: str, speed: float) -> str:
    """Same as engine_shim.word_timings_key; the shim can't import myna."""
    return hashlib.blake2b(f"{float(speed):.3f}\n{text}".encode(), digest_size=16).hexdigest()


def word_timings(text: str, *, speed: float, base_url: str, timeout: float = 1.0) -> dict | None:
    """Kokoro's own word times for a `synthesize(text, speed=speed)` that
    just returned: {"words": [[token, start_s, end_s], ...], "exact": bool}.

    None when the engine has none: another engine, a non-English Kokoro
    voice, or an engine started without the shim. Never raises.
    """
    try:
        resp = httpx.get(
            f"{base_url}/myna/word-timings/{word_timings_key(text, speed)}", timeout=timeout
        )
        if resp.status_code != 200:
            return None
        body = resp.json()
    except (httpx.HTTPError, ValueError):
        return None
    words = body.get("words") if isinstance(body, dict) else None
    if not isinstance(words, list) or not body.get("exact", False):
        return None
    return body


def engine_up(base_url: str, timeout: float = 2.0) -> bool:
    try:
        httpx.get(f"{base_url}/v1/models", timeout=timeout).raise_for_status()
        return True
    except Exception:
        return False


def loaded_models(base_url: str, timeout: float = 2.0) -> list[str]:
    """Model ids the engine currently holds in memory."""
    resp = httpx.get(f"{base_url}/v1/models", timeout=timeout)
    resp.raise_for_status()
    return [m.get("id", "") for m in resp.json().get("data", []) if isinstance(m, dict)]


def load_model(base_url: str, model: str, timeout: float = 600.0) -> None:
    httpx.post(f"{base_url}/v1/models", params={"model_name": model}, timeout=timeout).raise_for_status()


def unload_model(base_url: str, model: str, timeout: float = 30.0) -> None:
    resp = httpx.delete(f"{base_url}/v1/models", params={"model_name": model}, timeout=timeout)
    if resp.status_code not in (200, 204, 404):
        resp.raise_for_status()
