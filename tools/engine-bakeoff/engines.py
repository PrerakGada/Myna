"""Bake-off candidates and the fixed test texts.

Every candidate here runs inside mlx-audio, the runtime Myna already ships,
so none of them needs a second engine stack. `needs_ref` engines only speak
in a cloned voice; they get the same Kokoro-made reference clip so the
comparison is like for like.
"""

WARMUP = "Warming up the voice."

# 15 words — exactly Myna's first-chunk cap (config.py first_chunk_max_words).
FIRST_CHUNK = (
    "Myna reads the text you select aloud, so you can listen while you work."
)

# A realistic article paragraph: numbers, money, dates, abbreviations and a
# version string — the things that trip text normalization.
LONG_TEXT = (
    "On 14 March 2026, the city council approved a $4.2 million budget to repair "
    "the old harbour bridge, which first opened in 1928. Dr. Meera Iyer, who led "
    "the engineering review, said the steel frame was sound but the deck needed "
    "replacing within five years. Work will start in June and run for roughly "
    "eighteen months, with one lane kept open at all times. Residents raised two "
    "concerns at the public meeting: noise at night, and the cost of detours for "
    "delivery drivers, who already lose about 20 minutes a day in traffic. The "
    "council promised to limit loud work to between 7 a.m. and 9 p.m., and to "
    "publish a weekly schedule online. Local shops were cautiously optimistic. "
    "\"If the bridge closes, we close,\" said one café owner, \"so we're glad "
    "they're keeping it open.\" The contract goes to tender next month, and the "
    "final design, version 2.1, will be shared for comments before any work begins."
)

REFERENCE_TEXT = (
    "Hello there. This is a short sample of my speaking voice, recorded so the "
    "model can learn how I sound."
)

ENGINES = {
    "kokoro": {
        "name": "Kokoro 82M",
        "repo": "prince-canuma/Kokoro-82M",
        "gen": {"voice": "af_heart", "lang_code": "a"},
    },
    "kitten-nano": {
        "name": "Kitten TTS nano 0.8",
        "repo": "mlx-community/kitten-tts-nano-0.8",
        "gen": {},
    },
    "kitten-mini": {
        "name": "Kitten TTS mini 0.8",
        "repo": "mlx-community/kitten-tts-mini-0.8",
        "gen": {},
    },
    "soprano": {
        "name": "Soprano 1.1 80M",
        "repo": "mlx-community/Soprano-1.1-80M-bf16",
        "gen": {},
    },
    "pocket": {
        "name": "Pocket TTS (Kyutai)",
        "repo": "mlx-community/pocket-tts",
        "gen": {},
        "stream": True,
    },
    "pocket-clone": {
        "name": "Pocket TTS — cloned voice",
        "repo": "mlx-community/pocket-tts",
        "gen": {},
        "needs_ref": True,
        "stream": True,
    },
    "moss-nano": {
        "name": "MOSS-TTS-Nano 100M — cloned voice",
        "repo": "mlx-community/MOSS-TTS-Nano-100M",
        "gen": {},
        "needs_ref": True,
        "ref_text": REFERENCE_TEXT,
    },
    "qwen3-0.6b": {
        "name": "Qwen3-TTS 0.6B CustomVoice 8-bit",
        "repo": "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
        "gen": {"voice": "serena", "lang_code": "english"},
        "stream": True,
    },
    "chatterbox-turbo": {
        "name": "Chatterbox Turbo 8-bit",
        "repo": "mlx-community/chatterbox-turbo-8bit",
        "gen": {},
        "stream": True,
    },
    "supertonic3": {
        "name": "Supertonic 3 (ONNX)",
        "repo": "Supertone/supertonic-3",
        "runtime": "supertonic",
        "gen": {"voice": "F1", "steps": 8},
    },
}
