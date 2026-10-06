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
