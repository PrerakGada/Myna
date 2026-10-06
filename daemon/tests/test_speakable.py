"""myna.speakable: the text Myna speaks.

Three kinds of test, all of them load-bearing:

* stripping — real inputs (a Claude Code reply, a Wikipedia paragraph, a
  markdown table, a diff) lose their markup and keep their words;
* no false positives — prose that must come through exactly as written;
* idempotence — cleaning cleaned text changes nothing.
"""

import pytest

from myna import speakable as sp
from myna.speakable import (
    ARTICLE,
    BASE,
    CLAUDE_CODE,
    CODE_BLOCK_MARKER,
    CODE_SNIPPET_MARKER,
    changed,
    clean,
    preset_for,
    speakable,
)

# A real Claude Code reply from this repo's own sessions (Sep 2026), as the
# Stop hook hands it over: bold labels, bullets, inline code, an indented
# fence inside a list item, paths.
REAL_CC_REPLY = """All four engines are built in: Kokoro, Soprano, Pocket TTS and Chatterbox Turbo. **You can download, switch to and remove each one from the Engine page, and hovering a card (or clicking ⓘ) shows its measured numbers.** Your Mac is set up to try one a day; Kokoro is active and your voice is still `af_heart`.

**How I checked it:**
- Through the daemon, I switched to each engine and did a real read with the same request the app sends. All four spoke, the old model was unloaded, and the choice survived a restart.
- Both test suites pass: 301 daemon tests and 384 app tests.
- **I haven't clicked through the real window**, so the Download and Use buttons still need their first real press from you.

**What I changed on your Mac:**
- **The daemon now runs from the repo code instead of Homebrew.** It runs through a LaunchAgent called `dev.myna.daemon.src`. To go back:
  ```
  launchctl bootout gui/$(id -u)/dev.myna.daemon.src && just daemon-start
  ```
- **The voice engine's environment was upgraded** from mlx-audio 0.4.4 to 0.5.7, with the `sentencepiece` package added (Pocket TTS needs it). A rollback list of the old package versions is at `~/.cache/myna-bakeoff/mlx-audio-venv-before-0.5.7.txt`.

**Before any of this ships:**
- Nothing is committed yet.
- The installer (`dist/setup.sh`) now pins mlx-audio to the 0.5 line and adds `sentencepiece`. That needs a clean-VM install test, as the project notes require.

Say when you want it committed; I'd put it on a branch together with the dashboard work it builds on."""

# The other shape a Claude Code reply takes: headings, a code fence, paths
# with line numbers, a table, a unified diff outside any fence, a bare URL.
CC_REPLY_WITH_DIFF = """## Summary

The chunker was splitting mid-sentence. I fixed it in `/Users/nebula/Developer/myna/daemon/myna/chunking.py:42` and added tests in daemon/tests/test_chunking.py.

### What changed

1. `chunk_text` now splits on sentence ends only
2. The first chunk stays short (see `app.py:516-523`)

```python
def chunk_text(text, max_chars=1500):
    return [text]
```

| File | Tests |
|------|-------|
| `chunking.py` | 12 |
| `app.py` | — |

diff --git a/daemon/myna/chunking.py b/daemon/myna/chunking.py
index 3f2a1bc..9e8d7f0 100644
--- a/daemon/myna/chunking.py
+++ b/daemon/myna/chunking.py
@@ -10,7 +10,7 @@ def chunk_text(text, max_chars=1500):
-    sentences = re.split(r"\\s+", text)
+    sentences = re.split(r"(?<=[.!?])\\s+", text)
     chunks = []

Full log: https://github.com/PrerakGada/myna/actions/runs/123456 — all green."""

WIKIPEDIA = (
    "Paris is the capital and largest city of France.[1] With an estimated population of "
    "2,102,650 residents in January 2023[2][3] in an area of more than 105 km2 (41 sq mi),[4] "
    "Paris is the fourth-most populous city in the European Union.[a] The city is a major "
    "railway, highway and air-transport hub.[5, 6][citation needed]"
)

TABLE = """Engines compared:

| Engine | First word | Voices |
|:-------|-----------:|:------:|
| Kokoro | 0.17 s | 41 |
| Chatterbox | 1.5 s | 1 |

That's the whole table."""

# Prose that has to come through exactly as written, under every preset.
UNCHANGED = [
    "C++ and C# are languages; so is F#.",
    "Bring snacks, e.g. fruit, i.e. anything healthy, etc.",
    "3 * 4 = 12, and 2 * 3 * 4 = 24.",
    "The file_name and my_var_name variables hold snake_case values.",
    "It costs $4.99, or €20, or £1,000.50 — 15% off.",
    "Python's __init__ and __main__ are special names.",
    "Use and/or here; km/h is a unit, 24/7 is a schedule, TCP/IP is a stack.",
    "Call POST /v2/speakable and GET /v2/renders/{id}/audio.",
    "Redirect it to /dev/null.",
    "Upgrade from v1.2/v1.3 or Deno/Node.js.",
    "The first element is items[0] and the second is items[1].",
    "Multiply a*b*c, then compute 2**10.",
    "Delete *.pyc and *.pyo files.",
    "Send it to prerak@engaze.in or www.example.com.",
    "Dr. Smith arrived at 10:30 a.m. on Sept. 29.",
    "He said \"stop\" — then left… Really?",
    "The ratio was 3:1 and the score 2-1.",
    "Rock & roll, Q&A, AT&T.",
    "#1 priority is the #hashtag, not a heading.",
    "The temperature was ~15 degrees, and x ~ y.",
    "Order: first, then second; finally, third.",
    "A line with ✅ and ❌ and 🚀 emoji stays as it is.",
    "Use the -v flag, not --verbose.",
    "Ranges like 1-3 and 10–20 are fine.",
    "Hello world",
]


# --------------------------------------------------------------------------
# presets


@pytest.mark.parametrize(
    "source, kind, url, preset",
    [
        ("claude_code", None, False, CLAUDE_CODE),
        ("claude-code", None, False, CLAUDE_CODE),
        ("cc:myna", None, False, CLAUDE_CODE),
        ("announce", None, False, CLAUDE_CODE),
        ("article", None, False, ARTICLE),
        (None, None, True, ARTICLE),
        ("studio", "pdf", False, ARTICLE),
        ("studio", "epub", False, ARTICLE),
        ("studio", "web", False, ARTICLE),
        ("studio", "markdown", False, BASE),
        ("studio", None, False, BASE),
        ("selection", None, False, BASE),
        ("clipboard", None, False, BASE),
        ("replay", None, False, BASE),
        ("summary", None, False, BASE),
        ("playground", None, False, BASE),
        ("api", None, False, BASE),
        (None, None, False, BASE),
        ("something-new", None, False, BASE),
    ],
)
def test_preset_for(source, kind, url, preset):
    assert preset_for(source, kind=kind, url=url) == preset


def test_literal_reads_as_written():
    text = "  **bold** `code` https://github.com/x [1]  "
    assert speakable(text, source="claude_code", prep="literal") == text.strip()


def test_unknown_preset_falls_back_to_base():
    assert clean("**hi** there", "nonsense") == "hi there"


# --------------------------------------------------------------------------
# no false positives


@pytest.mark.parametrize("text", UNCHANGED)
@pytest.mark.parametrize("preset", [BASE, CLAUDE_CODE, ARTICLE])
def test_prose_comes_through_unchanged(text, preset):
    assert clean(text, preset) == text


def test_hard_wrapped_prose_keeps_its_sentences():
    text = "This is a paragraph that was\nhard-wrapped at a narrow width\nby an email client."
    assert clean(text, BASE) == text


def test_single_line_without_punctuation_is_not_given_a_full_stop():
    assert clean("Hello world", BASE) == "Hello world"
    assert not changed("Hello world", clean("Hello world", BASE))


# --------------------------------------------------------------------------
# markdown: the base pass


def test_emphasis_keeps_the_words():
    assert clean("This is **very** important and *quite* _subtle_.") == (
        "This is very important and quite subtle."
    )
    assert clean("***both*** and ~~struck~~ and __strong words__") == "both and struck and strong words"


def test_headings_become_sentences():
    assert clean("# Title\nBody text here.") == "Title.\nBody text here."
    assert clean("## Closing ##\n\nDone.") == "Closing.\n\nDone."
    assert clean("### What's new?\nThings.") == "What's new?\nThings."


def test_setext_heading_and_rules_are_dropped():
    assert clean("Title\n=====\n\nBody.") == "Title.\n\nBody."
    assert clean("Before.\n\n---\n\nAfter.") == "Before.\n\nAfter."
    assert clean("One\n* * *\nTwo") == "One.\n\nTwo"


def test_bullets_lose_markers_and_gain_pauses():
    text = "Changes:\n- first thing\n* second thing\n+ third thing\n• fourth thing"
    assert clean(text) == "Changes:\nfirst thing.\nsecond thing.\nthird thing.\nfourth thing"


def test_numbered_items_keep_their_numbers():
    assert clean("Steps:\n1. Install it\n2) Run it") == "Steps:\n1. Install it.\n2) Run it"


def test_list_item_continuation_is_one_sentence():
    text = "- a long item that\n  continues on the next line\n- next item"
    assert clean(text) == "a long item that continues on the next line.\nnext item"


def test_task_list():
    assert clean("- [x] write tests\n- [ ] ship it") == "Done: write tests.\nship it"


def test_blockquotes():
    assert clean("> Quoted words\n> > nested too") == "Quoted words\nnested too"


def test_links_keep_their_text():
    assert clean("Read [the docs](https://example.com/docs \"Docs\") now.") == "Read the docs now."
    assert clean("See [Myna][1] and [this][].\n\n[1]: https://myna.dev") == "See Myna and this."
    assert clean("Wiki: [Paris](https://en.wikipedia.org/wiki/Paris_(city)).") == "Wiki: Paris."


def test_images_keep_alt_text_in_base():
    assert clean("![A myna bird](bird.png) sings.") == "A myna bird sings."


def test_bare_urls_become_the_site_name():
    assert clean("See https://github.com/PrerakGada/myna/pull/12 for details.") == "See github.com for details."
    assert clean("Go to https://www.bbc.co.uk/news.") == "Go to bbc.co.uk."
    assert clean("(source: https://en.wikipedia.org/wiki/Paris_(disambiguation))") == "(source: en.wikipedia.org)"
    assert clean("Open <https://docs.python.org/3/>, please.") == "Open docs.python.org, please."


def test_local_urls_keep_the_port():
    assert clean("It serves on http://127.0.0.1:8766/v2/health.") == "It serves on localhost port 8766."
    assert clean("Open http://localhost:3000") == "Open localhost port 3000"


def test_fenced_code_is_skipped_with_a_marker():
    text = "Run this:\n\n```bash\nrm -rf build\n```\n\nThen rebuild."
    assert clean(text) == f"Run this:\n\n{CODE_BLOCK_MARKER}\n\nThen rebuild."


def test_tilde_fences_and_unclosed_fences():
    assert clean("A\n~~~\ncode\n~~~\nB") == f"A.\n{CODE_BLOCK_MARKER}\nB"
    # CommonMark: an unclosed fence runs to the end.
    assert clean("Before.\n```\nnever closed\nmore code") == f"Before.\n{CODE_BLOCK_MARKER}"


def test_a_longer_fence_needs_a_longer_close():
    text = "````md\n```\ninner\n```\n````\nAfter."
    assert clean(text) == f"{CODE_BLOCK_MARKER}\nAfter."


def test_inline_code_short_is_read_long_is_skipped():
    assert clean("Call `speakable()` then `just test-daemon`.") == "Call speakable() then just test-daemon."
    long = "Run `MYNA_ENGINE_AUTOSTART=1 uv run --with-editable . uvicorn --factory myna.app:create_app` first."
    assert clean(long) == f"Run {CODE_SNIPPET_MARKER} first."
    # A single long token (a path, a flag) is still read in the base pass.
    token = "Open `~/Library/Application Support/Myna` or `--with-editable=./daemon/myna/pkg`."
    assert clean(token) == "Open ~/Library/Application Support/Myna or --with-editable=./daemon/myna/pkg."


def test_code_spans_protect_their_contents():
    assert clean("Use `**kwargs` and `__init__` and `a_b_c`.") == "Use **kwargs and __init__ and a_b_c."
    assert clean("Double ``a `tick` inside`` works.") == "Double a tick inside works."


def test_backslash_escapes_are_literal():
    assert clean(r"Not \*emphasis\* and 5 \* 3 and \# not a heading") == "Not emphasis and 5 * 3 and # not a heading"


def test_html_bits():
    assert clean("Line one<br>line two and <b>bold</b> <!-- hidden --> &amp; more&nbsp;here") == (
        "Line one line two and bold & more here"
    )


def test_whitespace_collapses():
    assert clean("  lots   of\t\tspace  \n\n\n\nand   gaps  ") == "lots of space.\n\nand gaps"


def test_markdown_table_becomes_rows():
    assert clean(TABLE) == (
        "Engines compared:\n\n"
        "Engine: Kokoro; First word: 0.17 s; Voices: 41.\n"
        "Engine: Chatterbox; First word: 1.5 s; Voices: 1.\n\n"
        "That's the whole table."
    )


def test_table_without_header_text_and_empty_cells():
    text = "| | |\n|---|---|\n| a | — |\n| b | c |"
    assert clean(text) == "a.\nb, c"


def test_pipes_outside_a_table_are_untouched():
    text = "Pipe it: cat file | grep x | sort"
    assert clean(text) == text


# --------------------------------------------------------------------------
# citations and footnotes


def test_wikipedia_paragraph_loses_its_citations():
    assert clean(WIKIPEDIA) == (
        "Paris is the capital and largest city of France. With an estimated population of "
        "2,102,650 residents in January 2023 in an area of more than 105 km2 (41 sq mi), "
        "Paris is the fourth-most populous city in the European Union. The city is a major "
        "railway, highway and air-transport hub."
    )


def test_a_lone_marker_after_a_word_is_kept_but_after_punctuation_goes():
    assert clean("Index items[1] please.") == "Index items[1] please."
    assert clean("It was founded in 1850.[7] Then it grew.") == "It was founded in 1850. Then it grew."
    assert clean("As shown in [3], it works.") == "As shown in [3], it works."


def test_footnotes():
    text = "A claim.[^1] Another[^note].\n\n[^1]: The source, 2020."
    assert clean(text) == "A claim. Another.\n\nThe source, 2020."
    assert clean("Superscript marks.¹ Or two.²³ But 5 m² stays.") == "Superscript marks. Or two. But 5 m² stays."


# --------------------------------------------------------------------------
# claude_code preset


def test_real_claude_code_reply():
    out = clean(REAL_CC_REPLY, CLAUDE_CODE)
    assert out == (
        "All four engines are built in: Kokoro, Soprano, Pocket TTS and Chatterbox Turbo. You can "
        "download, switch to and remove each one from the Engine page, and hovering a card (or clicking ⓘ) "
        "shows its measured numbers. Your Mac is set up to try one a day; Kokoro is active and your voice "
        "is still af_heart.\n\n"
        "How I checked it:\n"
        "Through the daemon, I switched to each engine and did a real read with the same request the app "
        "sends. All four spoke, the old model was unloaded, and the choice survived a restart.\n"
        "Both test suites pass: 301 daemon tests and 384 app tests.\n"
        "I haven't clicked through the real window, so the Download and Use buttons still need their "
        "first real press from you.\n\n"
        "What I changed on your Mac:\n"
        "The daemon now runs from the repo code instead of Homebrew. It runs through a LaunchAgent called "
        "dev.myna.daemon.src. To go back:\n"
        "The voice engine's environment was upgraded from mlx-audio 0.4.4 to 0.5.7, with the sentencepiece "
        "package added (Pocket TTS needs it). A rollback list of the old package versions is at "
        "mlx-audio-venv-before-0.5.7.txt.\n\n"
        "Before any of this ships:\n"
        "Nothing is committed yet.\n"
        "The installer (setup.sh) now pins mlx-audio to the 0.5 line and adds sentencepiece. That needs a "
        "clean-VM install test, as the project notes require.\n\n"
        "Say when you want it committed; I'd put it on a branch together with the dashboard work it builds on."
    )
    for junk in ("**", "`", "```", "launchctl", "~/.cache"):
        assert junk not in out


def test_real_claude_code_reply_base_pass_marks_the_code():
    out = clean(REAL_CC_REPLY, BASE)
    assert CODE_BLOCK_MARKER in out
    assert "launchctl" not in out
    # The base pass doesn't shorten paths.
    assert "~/.cache/myna-bakeoff/mlx-audio-venv-before-0.5.7.txt" in out


def test_claude_code_reply_with_diff_table_and_paths():
    out = clean(CC_REPLY_WITH_DIFF, CLAUDE_CODE)
    assert out == (
        "Summary.\n\n"
        "The chunker was splitting mid-sentence. I fixed it in chunking.py line 42 and added tests in "
        "test_chunking.py.\n\n"
        "What changed.\n\n"
        "1. chunk_text now splits on sentence ends only.\n"
        "2. The first chunk stays short (see app.py lines 516 to 523).\n\n"
        "File: chunking.py; Tests: 12.\n"
        "File: app.py.\n\n"
        "Full log: github.com — all green."
    )


def test_claude_code_base_pass_leaves_the_diff_but_skips_the_fence():
    out = clean(CC_REPLY_WITH_DIFF, BASE)
    assert CODE_BLOCK_MARKER in out
    assert "@@ -10,7 +10,7 @@" in out
    assert "/Users/nebula/Developer/myna/daemon/myna/chunking.py:42" in out


@pytest.mark.parametrize(
    "text, spoken",
    [
        ("Edit /Users/x/proj/src/app.py:42 now.", "Edit app.py line 42 now."),
        ("See ~/Developer/myna/daemon/myna/app.py.", "See app.py."),
        ("In ./scripts/build.sh and ../lib/util.js:7:3.", "In build.sh and util.js line 7."),
        ("Look at apps/macos/Sources/Dashboard/HistoryPane.swift:120-140.", "Look at HistoryPane.swift lines 120 to 140."),
        ("Open `src/app.py` please.", "Open app.py please."),
        ("Fix app.py:42 and render.py#L10-L20.", "Fix app.py line 42 and render.py lines 10 to 20."),
        ("The folder ~/Developer/_myna-create/textprep is new.", "The folder textprep is new."),
        ("Config in ~/.config/myna/config.json.", "Config in config.json."),
        ("Binary at /opt/homebrew/bin/ffmpeg works.", "Binary at ffmpeg works."),
        # Not filesystem paths: left alone.
        ("Call /v2/speakable then /v1/audio/speech.", "Call /v2/speakable then /v1/audio/speech."),
        ("Pipe to /dev/null and use and/or.", "Pipe to /dev/null and use and/or."),
        ("Edit src/app.py soon.", "Edit src/app.py soon."),
        ("The PrerakGada/homebrew-tap repo.", "The PrerakGada/homebrew-tap repo."),
    ],
)
def test_claude_code_paths(text, spoken):
    assert clean(text, CLAUDE_CODE) == spoken


def test_claude_code_skips_code_without_a_marker():
    text = "Here is the fix:\n\n```python\nx = 1\n```\n\nThat's all."
    assert clean(text, CLAUDE_CODE) == "Here is the fix:\n\nThat's all."


def test_claude_code_reply_that_is_only_code_says_so():
    assert clean("```\nprint('hi')\n```", CLAUDE_CODE) == CODE_BLOCK_MARKER


def test_claude_code_tool_noise():
    text = (
        "⏺ Bash(git status)\n"
        "  ⎿  On branch main\n"
        "     nothing to commit\n"
        "✻ Cogitating… (esc to interrupt)\n"
        "⏺ The tree is clean, so I committed the change. … +12 lines (ctrl+o to expand)\n"
        "<function_calls>\n<invoke name=\"Bash\">ls</invoke>\n</function_calls>\n"
        "<system-reminder>internal</system-reminder>\n"
        "Done."
    )
    assert clean(text, CLAUDE_CODE) == "The tree is clean, so I committed the change.\n\nDone."


def test_claude_code_diff_ends_at_a_blank_line_so_a_list_after_it_survives():
    text = "@@ -1,2 +1,2 @@\n-old\n+new\n\n- a real bullet\n- another"
    assert clean(text, CLAUDE_CODE) == "a real bullet.\nanother"


# --------------------------------------------------------------------------
# article preset


ARTICLE_TEXT = """The Quiet Birds of Mumbai
Mynas are among the most common birds in the city.
Figure 1: A common myna on a balcony railing.
Photo: Getty Images
Advertisement
They learn to mimic car alarms, phones and people.[4][5]
![A myna](myna.jpg)
Story continues below advertisement
Researchers counted them for ten years.
References
^ Smith, J. (2020). Urban birds. Journal of Birds.
1. ^ Doe, A. Mynas. 2019."""


def test_article_preset():
    assert clean(ARTICLE_TEXT, ARTICLE) == (
        "The Quiet Birds of Mumbai.\n"
        "Mynas are among the most common birds in the city.\n"
        "They learn to mimic car alarms, phones and people.\n"
        "Researchers counted them for ten years."
    )


def test_article_references_early_in_the_text_are_read():
    text = "Notes\nThese notes explain the method we used in detail.\n" + ("More prose here. " * 20)
    out = clean(text, ARTICLE)
    assert out.startswith("Notes.\nThese notes explain")


def test_article_markdown_reference_section_stops_at_the_next_heading():
    text = "# Story\n" + ("Body text. " * 30) + "\n\n## References\n- Smith 2020\n- Doe 2019\n\n# Appendix\nExtra."
    out = clean(text, ARTICLE)
    assert "Smith" not in out and "Doe" not in out
    assert out.endswith("Appendix.\nExtra.")


def test_article_keeps_prose_that_mentions_figures():
    text = "Figure 3 shows the growth.\nThe photo: taken in 2019, it shows the bay."
    assert clean(text, ARTICLE) == "Figure 3 shows the growth.\nThe photo: taken in 2019, it shows the bay."


def test_article_drops_image_placeholders_and_alt_text():
    assert clean("Before [Image: a bird] after ![alt text](x.png).", ARTICLE) == "Before after."


def test_article_lines_are_paragraphs():
    # Extractors put one paragraph per line; each gets its own sentence end.
    assert clean("Heading\nParagraph one.\nParagraph two", ARTICLE) == "Heading.\nParagraph one.\nParagraph two"


# --------------------------------------------------------------------------
# idempotence and determinism


ALL_INPUTS = [REAL_CC_REPLY, CC_REPLY_WITH_DIFF, WIKIPEDIA, TABLE, ARTICLE_TEXT] + UNCHANGED + [
    "Use `` `**x**` `` here.",
    "***Bold italic*** then **_mixed_** then *__odd__*.",
    "&amp;lt;b&amp;gt; entity soup",
    "- [x] done\n- item with `a | b` code\n> - quoted item",
    "```\nunclosed",
]


@pytest.mark.parametrize("text", ALL_INPUTS)
@pytest.mark.parametrize("preset", [BASE, CLAUDE_CODE, ARTICLE])
def test_idempotent(text, preset):
    once = clean(text, preset)
    assert clean(once, preset) == once


@pytest.mark.parametrize("text", ALL_INPUTS)
def test_deterministic(text):
    assert len({clean(text, CLAUDE_CODE) for _ in range(5)}) == 1


def test_cleaning_across_presets_is_stable():
    # Text cleaned by one preset and read again under another (a History
    # replay of a Claude Code row, say) settles.
    once = clean(REAL_CC_REPLY, CLAUDE_CODE)
    assert clean(once, BASE) == once


# --------------------------------------------------------------------------
# chunk boundaries fall on real sentences


def test_structure_gives_the_chunker_sentence_ends():
    from myna import chunking

    text = "## Summary\n- first point\n- second point\n\nBody sentence."
    chunks = chunking.chunk_text(clean(text), max_chars=20)
    assert chunks == ["Summary.", "first point.", "second point.", "Body sentence."]


# --------------------------------------------------------------------------
# changed() and the substitution hook


def test_changed_ignores_spacing_only():
    assert not changed("a  b\nc", "a b c")
    assert changed("**a**", "a")


def test_substitution_stages_run_after_cleanup():
    seen = []

    def stage(text):
        seen.append(text)
        return text.replace("kubectl", "cube control")

    out = speakable("Run **kubectl** now.", source="selection", substitutions=[stage])
    assert seen == ["Run kubectl now."]
    assert out == "Run cube control now."


def test_empty_and_whitespace():
    assert clean("") == ""
    assert clean("   \n\n  ") == ""
    assert clean("---") == ""


def test_large_input_is_fast():
    import time

    text = (CC_REPLY_WITH_DIFF + "\n\n" + WIKIPEDIA + "\n\n") * 200  # ~400 KB
    start = time.perf_counter()
    clean(text, CLAUDE_CODE)
    assert time.perf_counter() - start < 10
    assert sp._MAX_PASSES >= 2
