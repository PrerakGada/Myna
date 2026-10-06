"""Turn a bake-off output folder into report.html: numbers + side-by-side audio.

    python3 report.py <out_dir>
"""

from __future__ import annotations

import html
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from engines import ENGINES, FIRST_CHUNK, LONG_TEXT  # noqa: E402


# From the numbers and Parakeet transcripts of the 28 Sep 2026 run — not from
# listening. Voice quality is still a human call.
VERDICTS = {
    "kokoro": "Keep as default. Fast, accurate, 8 languages.",
    "soprano": "Shortlist. As fast as Kokoro at a quarter of the memory. English only.",
    "pocket": "Shortlist. Streams its first audio in 20 ms. CC-BY-4.0 (credit Kyutai).",
    "pocket-clone": "Shortlist as the voice-cloning feature: 5 s of audio, same accuracy.",
    "chatterbox-turbo": "Shortlist as the expressive tier. Most accurate; 3.3 GB; extra first-load download.",
    "kitten-mini": "Works, but nothing Kokoro doesn't already do better.",
    "kitten-nano": "Reject. Babbles for 8 minutes on a 1-minute paragraph.",
    "moss-nano": "Reject. Skips sentences, invents words, 10 GB peak.",
    "qwen3-0.6b": "Not lightweight: 12 GB peak. Only viable with true streaming.",
    "supertonic3": "Hold. 31 languages, 44.1 kHz, but 0.8 s first word and a second runtime (ONNX).",
}


def fmt(v, spec="{:.2f}", dash="—"):
    return dash if v is None else spec.format(v)


def main() -> None:
    out = pathlib.Path(sys.argv[1]).resolve()
    rows = []
    for eid, spec in ENGINES.items():
        p = out / f"{eid}.json"
        if not p.exists():
            continue
        r = json.loads(p.read_text())
        r["name"] = spec["name"]
        rows.append(r)
    ok = sorted((r for r in rows if r.get("ok")), key=lambda r: r["first_audio_s"])
    bad = [r for r in rows if not r.get("ok")]

    trs = []
    for r in ok:
        trs.append(
            "<tr>"
            f"<th>{html.escape(r['name'])}<small>{html.escape(VERDICTS.get(r['engine'], r['repo']))}</small></th>"
            f"<td>{fmt(r['first_audio_s'], '{:.2f} s')}</td>"
            f"<td>{fmt(r.get('stream_first_s'), '{:.2f} s')}</td>"
            f"<td>{fmt(r.get('rtf'), '{:.1f}×')}</td>"
            f"<td>{fmt(r.get('peak_mem_mb'), '{:,.0f} MB')}</td>"
            f"<td>{fmt(r.get('disk_mb'), '{:,.0f} MB')}</td>"
            f"<td>{fmt(r.get('load_s'), '{:.1f} s')}</td>"
            f"<td>{fmt(r.get('wer') and r['wer'] * 100, '{:.0f}%')}</td>"
            f"<td>{fmt(r.get('sample_rate'), '{:,}', '—')}</td>"
            f"<td><audio controls preload=none src='{r['engine']}_short.wav'></audio>"
            f"<audio controls preload=none src='{r['engine']}_long.wav'></audio></td>"
            "</tr>"
        )
    fails = "".join(
        f"<li><b>{html.escape(r['name'])}</b> — {html.escape(r.get('error', '?'))}</li>"
        for r in bad
    )
    page = f"""<!doctype html><meta charset=utf-8>
<title>Myna engine bake-off</title>
<style>
:root{{--bg:#fff;--fg:#1d1d1f;--mute:#6e6e73;--line:#e5e5ea}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111;--fg:#f2f2f7;--mute:#98989d;--line:#2c2c2e}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,system-ui;margin:32px auto;max-width:1280px;padding:0 16px}}
table{{border-collapse:collapse;width:100%}}th,td{{padding:10px 8px;border-bottom:1px solid var(--line);text-align:right;vertical-align:middle}}
th{{text-align:left;font-weight:600}}th small{{display:block;color:var(--mute);font-weight:400}}
thead th{{color:var(--mute);font-weight:500;text-align:right}}thead th:first-child{{text-align:left}}
audio{{height:30px;width:230px;display:block;margin:2px 0}}p,li{{color:var(--mute)}}blockquote{{color:var(--mute);border-left:3px solid var(--line);margin:0;padding-left:12px}}
</style>
<h1>Myna engine bake-off</h1>
<p>Apple M5 Max · mlx-audio 0.5.7 · sorted by wait before the first word. Top player = the 15-word first chunk, bottom = the article paragraph.</p>
<table><thead><tr><th>Engine</th><th>First word</th><th>Streamed</th><th>Speed</th><th>Peak memory</th><th>Disk</th><th>Load</th><th>Word errors</th><th>Hz</th><th>Listen</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table>
{f'<h3>Failed</h3><ul>{fails}</ul>' if fails else ''}
<h3>Test text</h3><blockquote>{html.escape(FIRST_CHUNK)}</blockquote><br><blockquote>{html.escape(LONG_TEXT)}</blockquote>
<p>First word = time to synthesize Myna's first 15-word chunk (median of 3, warm). Speed = seconds of audio per second of work.
Word errors = Parakeet transcript vs the input; numbers and punctuation add the same noise to every engine.</p>
"""
    (out / "report.html").write_text(page)
    print(out / "report.html")


if __name__ == "__main__":
    main()
