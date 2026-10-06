"""Summaries meant for listening: the style prompts and the Ollama call.

The app summarizes with Apple's on-device model when it can and sends the
finished summary here as a plain read. This module is the fallback: a read
with `mode: "summary"` (and optionally `summary_style`) is summarized with
Ollama before it's spoken.

Both sides use the same wording. The Swift copy lives in
apps/macos/Sources/Summaries/SummaryPrompts.swift; change one, change the
other, word for word.

Long text: Ollama silently drops the start of a prompt that overflows its
context window, and the instructions sit at the start. So every call sets
`num_ctx`, and text that won't fit in one call is summarized in parts, then
the parts' digests are summarized together (map-reduce), inside one time
budget.
"""

from __future__ import annotations

import os
import re
import shutil
import time
from typing import Callable, Optional

import httpx

# ----- prompts: keep in sync with SummaryPrompts.swift -----

STYLES = ("tldr", "key_points", "action_items", "plain_english")
DEFAULT_STYLE = "tldr"

INSTRUCTIONS = (
    "You write summaries that Myna will read aloud, so write for listening. "
    "Use plain spoken sentences: no markdown, no headings, no bullet points, "
    "no numbered lists, and no symbols such as asterisks, hashes or dashes. "
    "Start with the content itself, never with a preamble such as "
    "\"Here is a summary\". Use only what the text says, and add no facts or "
    "opinions of your own."
)

_STYLE_PROMPTS = {
    "tldr": (
        "Summarize the text in two or three sentences, and no more. Lead with "
        "the most important fact, then add only what a listener most needs to "
        "know."
    ),
    "key_points": (
        "Give the key points of the text as a short spoken list of three to "
        "five points. Start each point with an ordinal word, in order: First, "
        "Second, Third, and so on. Use one or two full sentences per point."
    ),
    "action_items": (
        "Tell the listener what the text asks them to do, speaking to them as "
        "you, most important first. Give each action as one short sentence, "
        "with any deadline, place or contact the text gives. Leave out things "
        "that will simply happen to them. If the text asks nothing of them, "
        "say only: There's nothing you need to do."
    ),
    "plain_english": (
        "Rewrite the text in plain English so it is easy to follow by ear. "
        "Use short sentences and everyday words, and explain any jargon in "
        "passing. Keep all of the meaning and most of the detail: simplify, "
        "but do not shorten it much."
    ),
}

_PART_PROMPT = (
    "This is part {index} of {count} of a longer text. Write a compact digest "
    "of this part in plain sentences. Keep every main point, fact, number, "
    "name and decision, and anything the reader is asked to do."
)

_PARTS_PREFACE = (
    "The text below joins digests of consecutive parts of one longer text, "
    "in order. Treat it as one text."
)

# ----- sizes -----

# One fixed context for every call: a num_ctx that changes between calls
# makes Ollama reload the model. 8k tokens holds a ~4,000-word part plus the
# prompt and the answer, and keeps the KV cache of a 4B model near 1 GB.
OLLAMA_NUM_CTX = 8192
# Characters per part. English runs ~4 characters a token; 3.5 leaves room
# for names and numbers. 16,000 characters ≈ 4,600 tokens.
PART_CHARS = 16_000
# Plain English is a rewrite, so the answer is about as long as the part.
PLAIN_PART_CHARS = 9_000
# The whole job, however many parts, gets this long (seconds).
TOTAL_BUDGET_S = 180.0


class SummaryUnavailable(Exception):
    """The summary couldn't be made. `reason` is a stable code the app
    turns into a notice; `detail` is for logs."""

    def __init__(self, reason: str, detail: str = ""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


def normalize_style(style: Optional[str]) -> str:
    """An unknown or missing style reads as TL;DR, so an older daemon never
    rejects a newer app's request."""
    return style if style in _STYLE_PROMPTS else DEFAULT_STYLE


def style_prompt(style: Optional[str]) -> str:
    return _STYLE_PROMPTS[normalize_style(style)]


def build_summary_prompt(text: str, style: Optional[str] = None) -> str:
    """The whole prompt for one pass: instructions, the style, the text."""
    return f"{INSTRUCTIONS}\n\n{style_prompt(style)}\n\nTEXT:\n{text}"


def build_reduce_prompt(digests: list[str], style: Optional[str] = None) -> str:
    joined = "\n\n".join(digests)
    return f"{INSTRUCTIONS}\n\n{style_prompt(style)}\n\n{_PARTS_PREFACE}\n\nTEXT:\n{joined}"


def build_part_prompt(text: str, index: int, count: int) -> str:
    return f"{INSTRUCTIONS}\n\n{_PART_PROMPT.format(index=index, count=count)}\n\nTEXT:\n{text}"


# ----- splitting (mirrors SummaryChunker.swift) -----

_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def split_for_summary(text: str, max_chars: int) -> list[str]:
    """Split at paragraph breaks, then sentence ends, then spaces, so each
    part stays under `max_chars` and no sentence is cut unless it alone is
    longer than a part."""
    text = text.strip()
    if len(text) <= max_chars:
        return [text] if text else []
    pieces: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para:
            continue
        if len(para) <= max_chars:
            pieces.append(para)
            continue
        for sentence in _SENTENCE_END.split(para):
            if len(sentence) <= max_chars:
                pieces.append(sentence)
            else:
                pieces.extend(_split_words(sentence, max_chars))
    parts: list[str] = []
    current = ""
    for piece in pieces:
        candidate = f"{current}\n\n{piece}" if current else piece
        if len(candidate) <= max_chars:
            current = candidate
        else:
            if current:
                parts.append(current)
            current = piece
    if current:
        parts.append(current)
    return parts


def _split_words(sentence: str, max_chars: int) -> list[str]:
    out: list[str] = []
    current = ""
    for word in sentence.split():
        if len(word) > max_chars:
            if current:
                out.append(current)
                current = ""
            out.extend(word[i : i + max_chars] for i in range(0, len(word), max_chars))
            continue
        candidate = f"{current} {word}" if current else word
        if len(candidate) <= max_chars:
            current = candidate
        else:
            out.append(current)
            current = word
    if current:
        out.append(current)
    return out


# ----- tidying (mirrors SummaryPrompts.tidy in Swift) -----

_PREAMBLE = re.compile(
    r"^\s*(?:(?:sure|certainly|okay|ok)\b[,!.]?\s*)?here(?:'s|’s| is| are)\b[^\n:]{0,100}:\s*",
    re.IGNORECASE,
)
_LINE_MARKER = re.compile(r"^[ \t]*(?:[#>*•\-–]+|\d+[.)])[ \t]+", re.MULTILINE)


def tidy(summary: str) -> str:
    """Drop what a model adds despite the prompt: a "Here is…:" opener,
    list markers and bold marks. Everything else is left alone."""
    out = _PREAMBLE.sub("", summary.strip(), count=1)
    out = _LINE_MARKER.sub("", out)
    out = out.replace("**", "").replace("__", "")
    return out.strip()


# ----- Ollama -----


def summarize(
    text: str,
    *,
    model: str,
    base_url: str,
    think: bool = False,
    timeout: float = 60.0,
    style: Optional[str] = None,
    total_budget: float = TOTAL_BUDGET_S,
    clock: Callable[[], float] = time.monotonic,
) -> str:
    """Summarize `text` in `style` with Ollama. Raises SummaryUnavailable."""
    style = normalize_style(style)
    deadline = clock() + max(total_budget, timeout)

    def call(prompt: str) -> str:
        remaining = deadline - clock()
        if remaining <= 0:
            raise SummaryUnavailable("summary_timeout", "ran out of time between parts")
        return _generate(prompt, model=model, base_url=base_url, think=think, timeout=min(timeout, remaining))

    part_chars = PLAIN_PART_CHARS if style == "plain_english" else PART_CHARS
    parts = split_for_summary(text, part_chars)
    if len(parts) <= 1:
        return tidy(call(build_summary_prompt(text.strip(), style)))
    if style == "plain_english":
        # A rewrite of each part, read in order: shortening them into one
        # would defeat the style.
        return "\n\n".join(tidy(call(build_summary_prompt(p, style))) for p in parts)
    digests = [call(build_part_prompt(p, i + 1, len(parts))) for i, p in enumerate(parts)]
    # Very long input: the digests themselves may not fit one call.
    while len("\n\n".join(digests)) > PART_CHARS:
        groups = split_for_summary("\n\n".join(digests), PART_CHARS)
        digests = [call(build_part_prompt(g, i + 1, len(groups))) for i, g in enumerate(groups)]
    return tidy(call(build_reduce_prompt(digests, style)))


def _generate(prompt: str, *, model: str, base_url: str, think: bool, timeout: float) -> str:
    # think=False suppresses reasoning-model "thinking" so a summary returns in
    # seconds instead of minutes — see daemon design spec, summariser concern.
    try:
        resp = httpx.post(
            f"{base_url}/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "stream": False,
                "think": think,
                "options": {"num_ctx": OLLAMA_NUM_CTX},
            },
            timeout=timeout,
        )
        resp.raise_for_status()
    except httpx.TimeoutException as exc:
        raise SummaryUnavailable("summary_timeout", str(exc)) from exc
    except httpx.HTTPStatusError as exc:
        body = exc.response.text[:300]
        if exc.response.status_code == 404:
            raise SummaryUnavailable("summary_model_missing", f"{model}: {body}") from exc
        raise SummaryUnavailable("summary_failed", f"HTTP {exc.response.status_code}: {body}") from exc
    except httpx.HTTPError as exc:
        reason = "ollama_not_running" if ollama_installed() else "ollama_not_installed"
        raise SummaryUnavailable(reason, str(exc)) from exc
    out = (resp.json().get("response") or "").strip()
    if not out:
        raise SummaryUnavailable("summary_failed", "Ollama returned an empty answer")
    return out


# Where Ollama's CLI or app usually lands. The daemon runs under launchd
# with a short PATH, so `which` alone would miss a Homebrew install.
_OLLAMA_PATHS = (
    "/opt/homebrew/bin/ollama",
    "/usr/local/bin/ollama",
    "/Applications/Ollama.app",
    os.path.expanduser("~/Applications/Ollama.app"),
)


def ollama_installed() -> bool:
    return shutil.which("ollama") is not None or any(os.path.exists(p) for p in _OLLAMA_PATHS)


def model_listed(model: str, names: list[str]) -> bool:
    """`qwen3.5:4b` must be listed as is; a name without a tag means `:latest`."""
    want = model if ":" in model else f"{model}:latest"
    return any(n == want or n == model for n in names)


def ollama_status(*, base_url: str, model: str, timeout: float = 1.5) -> dict:
    """Is the fallback usable right now? One GET to /api/tags.

    state: "ready" | "model_missing" | "not_running" | "not_installed"
    """
    try:
        resp = httpx.get(f"{base_url}/api/tags", timeout=timeout)
        resp.raise_for_status()
        names = [m.get("name", "") for m in resp.json().get("models", [])]
    except (httpx.HTTPError, ValueError):
        state = "not_running" if ollama_installed() else "not_installed"
        return {"state": state, "model": model, "url": base_url}
    state = "ready" if model_listed(model, names) else "model_missing"
    return {"state": state, "model": model, "url": base_url}
