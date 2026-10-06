"""Build daemon/myna/voice_library_data.py — the voices Myna offers to copy.

Pocket TTS and Chatterbox can speak in any voice from a ~10 second clip.
Kyutai publishes a large set of such clips (huggingface.co/kyutai/tts-voices).
This picks the ones that are safe to ship in a commercial app and labels them:

  * vctk/           CC BY 4.0. 106 speakers, each with accent, region, age
                    and gender from the corpus's own speaker-info.txt
                    (vendored here). The `_enhanced` (cleaned) take is used.
  * alba-mackenna/  CC BY 4.0. Four characters by one voice actor.
  * voice-zero/     CC0. Four LibriVox audiobook narrators.

Left out on purpose: expresso/ and ears/ (CC BY-NC — non-commercial only),
cml-tts/ (French speakers), unmute-prod-website/ (mixed licences), and
voice-donations/ (CC0, but 228 anonymous clips with no labels to browse by).

    python3 tools/voice-library/build.py            # uses the pinned revision
    python3 tools/voice-library/build.py --latest   # re-pin to the repo head

Needs network (the Hugging Face API) and nothing outside the stdlib.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parents[1] / "daemon" / "myna" / "voice_library_data.py"
REPO = "kyutai/tts-voices"
PINNED = "323332d33f997de8394f24a193e1a76df720e01a"

ACCENTS = {
    "English": "English (England)",
    "British": "English (England)",
    "Scottish": "Scottish",
    "Irish": "Irish",
    "NorthernIrish": "Northern Irish",
    "Welsh": "Welsh",
    "American": "American",
    "Canadian": "Canadian",
    "Indian": "Indian",
    "SouthAfrican": "South African",
    "Australian": "Australian",
    "NewZealand": "New Zealand",
}
REGION_FIXES = {"SE England": "South-east England", "SW England": "South-west England",
                "NE England": "North-east England"}

VCTK_CREDIT = "CSTR VCTK Corpus, University of Edinburgh (CC BY 4.0)"
ALBA_CREDIT = "Voice-acted by Alba MacKenna (CC BY 4.0)"
ZERO_CREDIT = "LibriVox recording, via Voice-Zero (CC0)"


def _get(url: str):
    with urllib.request.urlopen(url, timeout=60) as resp:  # noqa: S310 - fixed HF host
        return json.load(resp)


def _tree(rev: str, folder: str) -> dict[str, int]:
    items = _get(f"https://huggingface.co/api/models/{REPO}/tree/{rev}/{folder}")
    return {i["path"]: i.get("size", 0) for i in items if i.get("type") == "file"}


def _vctk_speakers() -> dict[str, dict]:
    rows = {}
    for line in (HERE / "vctk-speaker-info.txt").read_text().splitlines()[1:]:
        parts = line.split()
        if len(parts) < 4:
            continue
        sid, age, gender, accent, *region = parts
        region_text = " ".join(region)
        if "(" in region_text:  # p280: "France (mic2 files unavailable)"
            region_text = region_text.split("(", 1)[0].strip()
        rows[sid] = {
            "age": int(age),
            "gender": {"F": "female", "M": "male"}.get(gender),
            "accent": accent,
            "region": REGION_FIXES.get(region_text, region_text),
        }
    return rows


def build(rev: str) -> list[dict]:
    entries: list[dict] = []

    speakers = _vctk_speakers()
    vctk = _tree(rev, "vctk")
    for path in sorted(vctk):
        if not path.endswith("_enhanced.wav"):
            continue
        sid = path.split("/")[1].split("_")[0]
        info = speakers.get(sid)
        if info is None or info["accent"] not in ACCENTS:
            continue  # p280's accent is "Unknown"
        group = ACCENTS[info["accent"]]
        entries.append({
            "id": f"vctk-{sid}",
            "name": info["region"] or group,
            "group": group,
            "gender": info["gender"],
            "age": info["age"],
            "detail": f"{group} · VCTK {sid}",
            "path": path,
            "size_kb": vctk[path] // 1024,
            "license": "CC BY 4.0",
            "credit": VCTK_CREDIT,
        })

    alba = _tree(rev, "alba-mackenna")
    for path in sorted(p for p in alba if p.endswith(".wav")):
        stem = path.rsplit("/", 1)[1].removesuffix(".wav")
        entries.append({
            "id": f"alba-{stem}",
            "name": f"Alba · {stem.replace('-', ' ').capitalize()}",
            "group": "Voice actor",
            "gender": None,
            "age": None,
            "detail": "A character voice by Alba MacKenna",
            "path": path,
            "size_kb": alba[path] // 1024,
            "license": "CC BY 4.0",
            "credit": ALBA_CREDIT,
        })

    zero = _tree(rev, "voice-zero")
    for path in sorted(p for p in zero if p.endswith(".wav")):
        stem = path.rsplit("/", 1)[1].removesuffix(".wav")
        entries.append({
            "id": f"narrator-{stem.replace('_', '-')}",
            "name": stem.replace("_", " ").title(),
            "group": "Audiobook narrators",
            "gender": None,
            "age": None,
            "detail": "LibriVox audiobook narrator",
            "path": path,
            "size_kb": zero[path] // 1024,
            "license": "CC0",
            "credit": ZERO_CREDIT,
        })
    return entries


def render(rev: str, entries: list[dict]) -> str:
    lines = [
        '"""Voices Myna can copy from a clip — generated, do not edit by hand.',
        "",
        "Regenerate with `python3 tools/voice-library/build.py`; the sources,",
        "licences and what was left out are documented there.",
        '"""',
        "",
        f"REPO = {REPO!r}",
        f"REVISION = {rev!r}",
        "",
        "ENTRIES: tuple[dict, ...] = (",
    ]
    lines += [f"    {json.dumps(e, ensure_ascii=False).replace(': null', ': None')}," for e in entries]
    lines.append(")")
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--latest", action="store_true", help="pin to the repo's current head")
    args = ap.parse_args()
    rev = _get(f"https://huggingface.co/api/models/{REPO}")["sha"] if args.latest else PINNED
    entries = build(rev)
    OUT.write_text(render(rev, entries))
    print(f"wrote {len(entries)} voices at {rev[:10]} → {OUT}")


if __name__ == "__main__":
    main()
