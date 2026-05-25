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
) -> bytes:
    resp = httpx.post(
        f"{base_url}/v1/audio/speech",
        json={
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "wav",
            "lang_code": lang_code,
            "speed": speed,
        },
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.content


def engine_up(base_url: str, timeout: float = 2.0) -> bool:
    try:
        httpx.get(f"{base_url}/v1/models", timeout=timeout).raise_for_status()
        return True
    except Exception:
        return False
