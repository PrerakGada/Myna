import httpx

_PROMPT = (
    "Summarize the following text as a tight, spoken-style summary meant for "
    "listening. Use clear flowing sentences. No markdown, no bullet points, no "
    "headings, no preamble. Keep it under about 150 words.\n\nTEXT:\n{text}"
)


def build_summary_prompt(text: str) -> str:
    return _PROMPT.format(text=text)


def summarize(text: str, *, model: str, base_url: str, timeout: float = 120.0) -> str:
    resp = httpx.post(
        f"{base_url}/api/generate",
        json={"model": model, "prompt": build_summary_prompt(text), "stream": False},
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()["response"].strip()
