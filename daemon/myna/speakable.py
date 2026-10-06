"""Speakable text: what Myna says, made from the text it was given.

Text used to reach the engine verbatim, so Myna read out asterisks,
backticks, "#" headings, table pipes, whole URLs, code and citation marks
like [12]. Claude Code replies, most of what Myna reads, are markdown
through and through. This module turns text into the words a listener
wants and leaves everything else alone.

It is pure: no I/O, no clock, no locale, no randomness. The same text,
source and prep always give the same result, which is what lets History
show a read "as heard" by running it again (POST /v2/speakable). Running
it on its own output changes nothing (idempotent), so text that was
already cleaned (Studio's importers, the bold-claims reader) passes
through untouched.

Stages, in order (`speakable`):

1. normalize    line endings, invisible characters, HTML comments/entities
2. cleanup      the base pass, plus the source's preset on top:
                  base         markdown syntax, fenced code, long inline
                               code, bare URLs, citation marks, tables
                  claude_code  also: code skipped without a marker, file
                               paths shortened to the file name, diff and
                               hunk lines, tool-call noise
                  article      also: figure captions, "Advertisement",
                               reference lists, image alt text
3. substitute   `Stage`s passed as `substitutions`, run on the cleaned text
                (and under `prep: literal` too). The daemon passes the
                pronunciation list (myna.pronunciations); a proofreading
                mode would be another stage.
4. finish       sentence breaks at structural line ends, whitespace.

The rule of the house is never change meaning. Every rule is written
narrowly: "C++", "e.g.", "3 * 4", "file_name", "__init__", "$4.99",
"and/or", "/v2/speakable" and "items[0]" all come through as written. The
no-false-positives tests in tests/test_speakable.py matter as much as the
stripping ones.

Emoji are left alone, deliberately. Dropping them can change meaning
(a ✅ and a ❌ row read the same), and mapping them to words depends on
context; that belongs in the substitution stage, not here.
"""

from __future__ import annotations

import html
import re
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence
from urllib.parse import urlsplit

Stage = Callable[[str], str]

PREP_AUTO = "auto"
PREP_LITERAL = "literal"
PREPS = (PREP_AUTO, PREP_LITERAL)

BASE = "base"
CLAUDE_CODE = "claude_code"
ARTICLE = "article"
PRESETS = (BASE, CLAUDE_CODE, ARTICLE)

# What a skipped fenced code block says (base and article presets). Claude
# Code replies skip code without a word; see _blocks.
CODE_BLOCK_MARKER = "Code block skipped."
# What an inline code span too long to read says.
CODE_SNIPPET_MARKER = "a code snippet"

# Inline code is read when it is at most this long, or a single token (an
# identifier, a flag, a path) up to _CODE_TOKEN_MAX.
_CODE_READ_MAX = 40
_CODE_TOKEN_MAX = 80

# Cleanup runs to a fixed point: removing one layer of markup can expose
# another (`**x**` inside a code span). Three passes settle every input in
# the test corpus; the cap only bounds pathological text.
_MAX_PASSES = 4

_CC_SOURCES = frozenset({"claude_code", "claude-code", "claudecode", "cc", "announce"})
_ARTICLE_SOURCES = frozenset({"article", "web", "url"})
_ARTICLE_KINDS = frozenset({"article", "web", "pdf", "epub"})


# --------------------------------------------------------------------------
# public API


def preset_for(source: Optional[str], *, kind: Optional[str] = None, url: bool = False) -> str:
    """The preset a source gets under `prep: auto`.

    Claude Code (`claude_code`, the registry's `cc:<project>`, v1
    `/announce`) → claude_code. An article read, a URL, or a Studio document
    whose `kind` is web/pdf/epub → article. Everything else (selection,
    clipboard, replay, summary, playground, api, studio text, unknown) →
    base. Unknown sources never fail; they get the base pass.
    """
    s = (source or "").strip().lower()
    if s in _CC_SOURCES or s.startswith("cc:"):
        return CLAUDE_CODE
    if s in _ARTICLE_SOURCES or url or (kind or "").strip().lower() in _ARTICLE_KINDS:
        return ARTICLE
    return BASE


def speakable(
    text: str,
    *,
    source: Optional[str] = None,
    prep: str = PREP_AUTO,
    kind: Optional[str] = None,
    url: bool = False,
    substitutions: Sequence[Stage] = (),
) -> str:
    """The text Myna should speak for `text` read from `source`.

    `prep="literal"` skips cleanup (only the ends are trimmed).
    `substitutions` are str→str stages run after cleanup, under either
    prep: the pronunciation list is one (myna.pronunciations), and a
    pronunciation is about how a word sounds, not which text is read.
    """
    if prep == PREP_LITERAL:
        out = (text or "").strip()
    else:
        out = clean(text, preset_for(source, kind=kind, url=url))
    if substitutions:
        for stage in substitutions:
            out = stage(out)
        out = _tidy(out)
    return out


def clean(text: str, preset: str = BASE) -> str:
    """The cleanup stages alone, run to a fixed point."""
    if preset not in PRESETS:
        preset = BASE
    original = text or ""
    out = original
    for _ in range(_MAX_PASSES):
        nxt = _clean_once(out, preset)
        if nxt == out:
            break
        out = nxt
    if not out and preset == CLAUDE_CODE and _FENCE_OPEN_RE.search(original):
        # A reply that was nothing but code: say so rather than say nothing.
        return CODE_BLOCK_MARKER
    return out


def changed(before: str, after: str) -> bool:
    """Whether cleanup changed anything a listener could hear: the words or
    punctuation differ, not just spacing or line breaks."""
    return " ".join((before or "").split()) != " ".join((after or "").split())


# --------------------------------------------------------------------------
# one pass


def _clean_once(text: str, preset: str) -> str:
    text = _normalize(text, preset)
    blocks = _blocks(text, preset)
    many_cites = len(_CITE_COUNT_RE.findall(text)) >= 2
    for block in blocks:
        if block.kind != "marker":
            block.lines = [_inline(line, preset, many_cites) for line in block.lines]
    return _finish(blocks)


# ----- 1. normalize

_INVISIBLE_RE = re.compile("[​‌‍⁠﻿­-]")
_SPACES_RE = re.compile("[  -   　\t\f\v]")
_HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
_ENTITY_RE = re.compile(r"&(?:#\d{1,6}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,8});")
# Claude Code transcripts and tool plumbing that sometimes rides along with
# a reply. Only whole, closed blocks.
_CC_XML_BLOCK_RE = re.compile(
    r"<(function_calls|function_results|tool_use|tool_result|system-reminder|thinking)\b[^>]*>.*?</\1>",
    re.S,
)


def _normalize(text: str, preset: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace(" ", "\n").replace(" ", "\n\n")
    text = _INVISIBLE_RE.sub("", text)
    text = _HTML_COMMENT_RE.sub("", text)
    if preset == CLAUDE_CODE:
        text = _CC_XML_BLOCK_RE.sub("", text)
    text = _ENTITY_RE.sub(lambda m: html.unescape(m.group(0)), text)
    return _SPACES_RE.sub(" ", text)


# ----- 2a. blocks: one pass over lines, markdown structure and presets


@dataclass
class _Block:
    # para | heading | item | row | marker
    kind: str
    lines: list[str] = field(default_factory=list)
    # A blank line separated this block from the one before it.
    gap_before: bool = False


_FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})", re.M)
_FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
_QUOTE_RE = re.compile(r"^\s{0,3}(?:>[ \t]?)+")
_HEADING_RE = re.compile(r"^\s{0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
_HEADING_EMPTY_RE = re.compile(r"^\s{0,3}#{1,6}[ \t]*$")
_RULE_RE = re.compile(r"^\s{0,3}([-*_=])(?:[ \t]*\1){2,}[ \t]*$")
_BULLET_RE = re.compile(r"^\s*[-*+•◦▪‣][ \t]+(.*)$")
_NUMBERED_RE = re.compile(r"^\s*\d{1,3}[.)][ \t]+.*$")
_TASK_RE = re.compile(r"^\[([ xX])\][ \t]+(.*)$")
_REFDEF_RE = re.compile(r"^\s{0,3}\[(?!\^)[^\]\n]+\]:[ \t]*\S+(?:[ \t]+[\"'(].*[\"')])?[ \t]*$")
_FOOTDEF_RE = re.compile(r"^\s{0,3}\[\^[^\]\n]+\]:[ \t]*(.*)$")
_TABLE_DELIM_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$")
_CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")
_EMPTY_CELL_RE = re.compile(r"^[\s\-–—]*$")

# claude_code: diffs outside a fence, and Claude Code's terminal chrome.
_DIFF_START_RE = re.compile(
    r"^(?:diff --git |index [0-9a-f]{6,}\.\.[0-9a-f]{6,}|@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@"
    r"|--- (?:a/|/dev/null)|\+\+\+ (?:b/|/dev/null))"
)
_DIFF_LINE_RE = re.compile(
    r"^(?:[+\- \\]|@@|diff --git |index |(?:new|deleted) file mode|similarity index"
    r"|rename (?:from|to) |Binary files )"
)
_CC_TOOL_CALL_RE = re.compile(r"^\s*[⏺●]\s*[A-Z][A-Za-z]*\(.*$")
_CC_TOOL_RESULT_RE = re.compile(r"^\s*⎿")
_CC_SPINNER_RE = re.compile(r"^\s*[✻✳✶✢✽✺][ \t]")
_CC_GLYPH_RE = re.compile(r"^\s*[⏺●][ \t]+")

# article: page furniture.
_AD_LINE_RE = re.compile(
    r"^[\W_]*(?:advertisements?|sponsored(?: content)?|paid (?:content|post)|continue reading(?: below)?"
    r"|(?:story|article) continues below(?: (?:the )?advertisement)?|skip (?:advertisement|ad)"
    r"|scroll to continue(?: with content)?)[\W_]*$",
    re.I,
)
_CAPTION_RE = re.compile(
    r"^(?:figure|fig\.?|table|image|photo|photograph|illustration|plate|exhibit|chart|graph|map|video)"
    r"\s*\d+[a-z]?\s*[.:|—–-]\s",
    re.I,
)
_CREDIT_RE = re.compile(
    r"^(?:(?:photo|image|picture|illustration|photograph|video|graphic|map)s?(?: credits?| source| by)?"
    r"|(?:credits?|source|courtesy)(?=\s*:\s*(?:getty|reuters|ap\b|afp|shutterstock|alamy|istock|unsplash|epa)))"
    r"\s*:\s*\S",
    re.I,
)
_CAPTION_MAX = 300
_REF_HEAD_RE = re.compile(
    r"^\s{0,3}(#{1,6}[ \t]*)?(?:references|notes|footnotes|endnotes|sources|bibliography|works cited"
    r"|citations|further reading|external links|notes and references)[ \t]*:?[ \t]*$",
    re.I,
)
# A reference list only counts past this share of the text, so a "Notes"
# section early in a piece is read.
_REF_MIN_POSITION = 0.5
_CARET_LINE_RE = re.compile(r"^\s*(?:\d{1,3}[.)][ \t]*)?\^[ \t]")
_HEADING_LEVEL_RE = re.compile(r"^\s{0,3}(#{1,6})[ \t]")


def _is_table_start(lines: list[str], i: int) -> bool:
    return (
        i + 1 < len(lines)
        and "|" in lines[i]
        and "|" in lines[i + 1]
        and "-" in lines[i + 1]
        and bool(_TABLE_DELIM_RE.match(lines[i + 1]))
    )


def _cells(line: str) -> list[str]:
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip().replace("\\|", "|") for c in _CELL_SPLIT_RE.split(body)]


def _table_rows(header: list[str], body: list[list[str]]) -> list[str]:
    """Each row as one sentence: "Header: cell; Header: cell." Empty cells
    and bare dashes are skipped; a table with no header text lists cells."""
    rows = []
    named = any(h for h in header)
    for cells in body or [header]:
        parts = []
        for idx, cell in enumerate(cells):
            if _EMPTY_CELL_RE.match(cell):
                continue
            head = header[idx] if body and named and idx < len(header) else ""
            parts.append(f"{head}: {cell}" if head else cell)
        if parts:
            rows.append(("; " if named and body else ", ").join(parts))
    return rows


def _blocks(text: str, preset: str) -> list[_Block]:
    lines = text.split("\n")
    total = max(1, len(text))
    offsets = []
    pos = 0
    for line in lines:
        offsets.append(pos)
        pos += len(line) + 1

    blocks: list[_Block] = []
    gap = False

    def add(kind: str, line: str) -> _Block:
        nonlocal gap
        block = _Block(kind, [line], gap_before=gap)
        blocks.append(block)
        gap = False
        return block

    def current(kind: str) -> Optional[_Block]:
        return blocks[-1] if blocks and not gap and blocks[-1].kind == kind else None

    i = 0
    n = len(lines)
    in_diff = False
    while i < n:
        raw = lines[i]

        # Fenced code: everything to the closing fence (or the end, as
        # CommonMark does for an unclosed one).
        fence = _FENCE_RE.match(raw)
        if fence:
            mark = fence.group(1)
            j = i + 1
            while j < n:
                close = _FENCE_RE.match(lines[j])
                if close and close.group(1)[0] == mark[0] and len(close.group(1)) >= len(mark) and not close.group(2).strip():
                    break
                j += 1
            if preset != CLAUDE_CODE:
                add("marker", CODE_BLOCK_MARKER)
            i = j + 1
            continue

        if not raw.strip():
            gap = True
            i += 1
            continue

        if preset == CLAUDE_CODE:
            if in_diff or _DIFF_START_RE.match(raw):
                if _DIFF_LINE_RE.match(raw) or _DIFF_START_RE.match(raw):
                    in_diff = True
                    # A blank line ends the diff unless another diff header follows.
                    j = i + 1
                    if j < n and not lines[j].strip():
                        k = j
                        while k < n and not lines[k].strip():
                            k += 1
                        if k >= n or not _DIFF_START_RE.match(lines[k]):
                            in_diff = False
                    i += 1
                    continue
                in_diff = False
            if _CC_TOOL_CALL_RE.match(raw) or _CC_TOOL_RESULT_RE.match(raw) or _CC_SPINNER_RE.match(raw):
                # The tool's output runs on in indented lines below it.
                i += 1
                while i < n and lines[i].strip() and lines[i][:1] in " \t" and not _CC_GLYPH_RE.match(lines[i]):
                    i += 1
                continue
            raw = _CC_GLYPH_RE.sub("", raw)

        line = _QUOTE_RE.sub("", raw)
        if not line.strip():
            gap = True
            i += 1
            continue

        if preset == ARTICLE:
            stripped = line.strip()
            if _AD_LINE_RE.match(stripped) or _CARET_LINE_RE.match(stripped):
                i += 1
                continue
            if len(stripped) <= _CAPTION_MAX and (_CAPTION_RE.match(stripped) or _CREDIT_RE.match(stripped)):
                i += 1
                continue
            if _REF_HEAD_RE.match(line) and offsets[i] / total >= _REF_MIN_POSITION:
                # Drop the list: to the next heading of the same or a higher
                # level if the list had a markdown heading, else to the end.
                level = _HEADING_LEVEL_RE.match(line)
                j = i + 1
                if level:
                    depth = len(level.group(1))
                    while j < n:
                        nxt = _HEADING_LEVEL_RE.match(lines[j])
                        if nxt and len(nxt.group(1)) <= depth:
                            break
                        j += 1
                else:
                    j = n
                i = j
                continue
            if _FOOTDEF_RE.match(line):
                i += 1
                continue

        if _is_table_start(lines, i):
            header = _cells(line)
            j = i + 2
            body = []
            while j < n and lines[j].strip() and "|" in lines[j]:
                body.append(_cells(_QUOTE_RE.sub("", lines[j])))
                j += 1
            for row in _table_rows(header, body):
                add("row", row)
            i = j
            continue

        if _RULE_RE.match(line):
            # A thematic break, or a setext underline: either way the
            # previous block is over.
            gap = True
            i += 1
            continue

        if _HEADING_EMPTY_RE.match(line):
            i += 1
            continue
        heading = _HEADING_RE.match(line)
        if heading:
            add("heading", heading.group(1))
            i += 1
            continue

        if _REFDEF_RE.match(line):
            i += 1
            continue
        footdef = _FOOTDEF_RE.match(line)
        if footdef:
            add("para", footdef.group(1))
            i += 1
            continue

        bullet = _BULLET_RE.match(line)
        if bullet:
            item = bullet.group(1)
            task = _TASK_RE.match(item)
            if task:
                item = ("Done: " if task.group(1) in "xX" else "") + task.group(2)
            add("item", item)
            i += 1
            continue
        if _NUMBERED_RE.match(line):
            add("item", line.strip())
            i += 1
            continue

        # Plain text: a continuation of the open list item or paragraph, or
        # a new paragraph. Article text is one paragraph per line (the
        # extractors don't hard-wrap), so every line there stands alone.
        item = current("item")
        if item is not None:
            item.lines[-1] = f"{item.lines[-1]} {line.strip()}"
        elif preset != ARTICLE and current("para") is not None:
            blocks[-1].lines.append(line)
        else:
            add("para", line)
        i += 1

    return blocks


# ----- 2b. inline: one line at a time

_STASH_RE = re.compile("(\\d+)")
_CODE_SPAN_RE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
_ESCAPE_RE = re.compile(r"\\([\\`*_{}\[\]()#+\-.!|~>])")
_BR_RE = re.compile(r"<br\s*/?>", re.I)
_INLINE_TAG_RE = re.compile(
    r"</?(?:b|i|em|strong|u|s|del|ins|mark|small|sup|sub|kbd|code|span|abbr|cite|q|samp|var|font)"
    r"(?:\s[^<>]*)?>",
    re.I,
)
_LINK_TARGET = r"\((?:[^()\s]|\([^()\s]*\))*(?:\s+(?:\"[^\"]*\"|'[^']*'))?\)"
_IMAGE_RE = re.compile(r"!\[([^\]\n]*)\]" + _LINK_TARGET)
_LINK_RE = re.compile(r"(?<!\\)\[([^\]\n]+)\]" + _LINK_TARGET)
# "[text][ref]"; never "[2][3]", which is two citation marks.
_REFLINK_RE = re.compile(r"(?<![\\\]])\[(?![1-9]\d{0,2}(?:\s*[,–—-]\s*\d{1,3})*\])([^\]\n]+)\]\[[^\]\n]*\]")
_AUTOLINK_RE = re.compile(r"<((?:https?|ftp)://[^\s<>]+)>")
_URL_RE = re.compile(r"(?<![\w@/])(?:https?|ftp)://[^\s<>\"'`\]\[{}|\\^]+")
_URL_TRAIL = ".,;:!?'\""
_LOOPBACK = frozenset({"localhost", "127.0.0.1", "0.0.0.0", "::1"})
_FOOTREF_RE = re.compile(r"\[\^[^\]\s]+\]")
_PLACEHOLDER_RE = re.compile(r"\[(?:image|photo|picture|graphic|video|figure)(?::[^\]\n]*)?\]", re.I)

_CITE_BODY = (
    r"(?:[1-9]\d{0,2}(?:\s*[,–—-]\s*\d{1,3})*|[a-z]|note \d{1,3}|nb \d{1,3}"
    r"|(?:citation|clarification|verification|page|year|date|source|better source|full citation) needed"
    r"|who\?|when\?|which\?|where\?|by whom\?|according to whom\?|dubious(?: [^\]\n]{0,30})?"
    r"|failed verification|original research\??|unreliable source\??|not in citation given)"
)
_CITE_COUNT_RE = re.compile(r"(?<=[\w.,;:!?)\"'”’\]])\[[1-9]\d{0,2}(?:\s*[,–—-]\s*\d{1,3})*\]")
# Always a citation: attached to closing punctuation ("city.[12]").
_CITE_AFTER_PUNCT_RE = re.compile(r"(?<=[.,;:!?)\"'”’\]])\[" + _CITE_BODY + r"\]")
# Attached to a word ("city[12]"): only when the text has two or more
# numeric markers, so a lone "items[1]" is left alone.
_CITE_AFTER_WORD_RE = re.compile(r"(?<=\w)\[" + _CITE_BODY + r"\](?=[\s.,;:!?)\"'”’\[]|$)")
_SUPERSCRIPT_CITE_RE = re.compile(r"(?<=[.,;:!?)\"'”’\]])[⁰¹²³⁴⁵⁶⁷⁸⁹]+")

_BOLD_ITALIC_RE = re.compile(r"(?<![\w*\\])\*\*\*(?![\s*])([^\n]+?)(?<![\s*\\])\*\*\*(?![\w*])")
_BOLD_RE = re.compile(r"(?<![\w*\\])\*\*(?![\s*])([^\n]+?)(?<![\s*\\])\*\*(?![\w*])")
_ITALIC_RE = re.compile(r"(?<![\w*\\])\*(?![\s*])([^\n*]+?)(?<![\s*\\])\*(?![\w*])")
_UBOLD_RE = re.compile(r"(?<![\w\\])__(?![\s_])([^\n]+?)(?<![\s_\\])__(?!\w)")
_UITALIC_RE = re.compile(r"(?<![\w\\])_(?![\s_])([^\n_]+?)(?<![\s_\\])_(?!\w)")
_STRIKE_RE = re.compile(r"(?<![~\\])~~(?![\s~])([^\n]+?)(?<![\s~\\])~~(?!~)")
_IDENTIFIER_RE = re.compile(r"^\w+$")

_CC_EXPAND_RE = re.compile(
    r"[ \t]*(?:…[ \t]*\+\d+ lines?[ \t]*)?\((?:ctrl|ctl)\+[a-z] to (?:expand|see more|collapse|show more)\)", re.I
)

# claude_code: file paths. A path is shortened to its last component when
# it is plainly a filesystem path: it starts at ~/ ./ ../ or a filesystem
# root (/Users, /tmp, /opt …), or it is relative with a file extension and
# either two or more slashes, a line number, or backticks around it. API
# routes (/v2/speakable), "and/or", "km/h", "/dev/null" and "v1.2/v1.3"
# don't qualify.
_SEG = r"\.?[\w@+-](?:[\w.@+-]*[\w@+-])?"
_LOC = r"(?P<loc>:\d+(?:[-–]\d+)?(?::\d+)?|#L\d+(?:-L?\d+)?)"
_PATH_RE = re.compile(
    r"(?<![\w/.~@:\\-])"
    r"(?P<path>(?:~|\.{1,2})?(?:/" + _SEG + r")+/?|" + _SEG + r"(?:/" + _SEG + r")+/?)"
    + _LOC + r"?(?![\w/])"
)
_FILE_LOC_RE = re.compile(
    r"(?<![\w/.~@:\\-])(?P<path>[\w@+-][\w.@+-]*\.[A-Za-z][A-Za-z0-9]{0,7})" + _LOC + r"(?![\w:])"
)
_EXT_RE = re.compile(r"^\.?[^.]+(?:\.[^.]+)*\.[A-Za-z][A-Za-z0-9]{0,7}$")
_FS_ROOTS = frozenset({
    "Users", "home", "private", "tmp", "var", "opt", "usr", "Library", "Applications",
    "Volumes", "System", "etc", "bin", "sbin", "mnt", "srv", "root",
})
_LOC_NUMS_RE = re.compile(r"\d+")


def _loc_words(loc: Optional[str]) -> str:
    if not loc:
        return ""
    nums = _LOC_NUMS_RE.findall(loc)
    if loc.startswith(":") and len(nums) == 2 and not re.search(r"[-–]", loc):
        nums = nums[:1]  # file:line:column → the line
    if len(nums) >= 2:
        return f" lines {nums[0]} to {nums[1]}"
    return f" line {nums[0]}"


def _shorten_path(path: str, loc: Optional[str], in_code: bool) -> Optional[str]:
    trimmed = path.rstrip("/")
    last = trimmed.rsplit("/", 1)[-1]
    if not last or last in (".", "..", "~"):
        return None
    rooted = path.startswith(("~/", "./", "../"))
    if not rooted and path.startswith("/"):
        rooted = path[1:].split("/", 1)[0] in _FS_ROOTS
    has_ext = bool(_EXT_RE.match(last))
    relative = not path.startswith(("/", "~", "."))
    if rooted or (relative and has_ext and (path.count("/") >= 2 or loc or in_code)):
        return last + _loc_words(loc)
    return None


def _shorten_paths(text: str, *, in_code: bool = False) -> str:
    def repl(m: re.Match) -> str:
        short = _shorten_path(m.group("path"), m.group("loc"), in_code)
        return short if short is not None else m.group(0)

    text = _PATH_RE.sub(repl, text)
    return _FILE_LOC_RE.sub(lambda m: m.group("path") + _loc_words(m.group("loc")), text)


def _speak_url(url: str) -> tuple[str, str]:
    """(what to say, trailing text that wasn't part of the URL)."""
    tail = ""
    while url and url[-1] in _URL_TRAIL:
        tail = url[-1] + tail
        url = url[:-1]
    while url.endswith(")") and url.count(")") > url.count("("):
        tail = ")" + tail
        url = url[:-1]
    try:
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
        port = parts.port
    except ValueError:
        host, port = "", None
    if not host:
        return "link", tail
    if host in _LOOPBACK or host.startswith("127."):
        return ("localhost" + (f" port {port}" if port else "")), tail
    if host.startswith("www."):
        host = host[4:]
    return host, tail


def _speak_urls(text: str) -> str:
    def repl(m: re.Match) -> str:
        spoken, tail = _speak_url(m.group(0))
        return spoken + tail

    return _URL_RE.sub(repl, text)


def _code_span(content: str, preset: str) -> str:
    content = content.strip()
    if not content:
        return ""
    content = _speak_urls(content)
    if preset == CLAUDE_CODE:
        content = _shorten_paths(content, in_code=True)
    single_token = not any(ch.isspace() for ch in content)
    if len(content) <= _CODE_READ_MAX or (single_token and len(content) <= _CODE_TOKEN_MAX):
        return content
    return CODE_SNIPPET_MARKER


def _emphasis(s: str) -> str:
    s = _BOLD_ITALIC_RE.sub(r"\1", s)
    s = _BOLD_RE.sub(r"\1", s)
    s = _ITALIC_RE.sub(r"\1", s)
    # `__init__` and `__main__` are names, not bold.
    s = _UBOLD_RE.sub(lambda m: m.group(0) if _IDENTIFIER_RE.match(m.group(1)) else m.group(1), s)
    s = _UITALIC_RE.sub(r"\1", s)
    return _STRIKE_RE.sub(r"\1", s)


def _inline(s: str, preset: str, many_cites: bool) -> str:
    kept: list[str] = []

    def stash(value: str) -> str:
        kept.append(value)
        return f"{len(kept) - 1}"

    # Code spans first: nothing inside them is markdown.
    s = _CODE_SPAN_RE.sub(lambda m: stash(_code_span(m.group(2), preset)), s)
    s = s.replace("`", "")
    # Escaped characters are literal: keep them out of every rule below.
    s = _ESCAPE_RE.sub(lambda m: stash(m.group(1)), s)

    s = _BR_RE.sub(" ", s)
    s = _INLINE_TAG_RE.sub("", s)
    if preset == ARTICLE:
        # Images go entirely, with the space in front of them.
        s = re.sub(r"[ \t]*" + _IMAGE_RE.pattern, "", s)
        s = re.sub(r"[ \t]*" + _PLACEHOLDER_RE.pattern, "", s, flags=re.I)
    s = _IMAGE_RE.sub(r"\1", s)
    s = _LINK_RE.sub(r"\1", s)
    s = _REFLINK_RE.sub(r"\1", s)
    s = _AUTOLINK_RE.sub(r"\1", s)
    s = _speak_urls(s)
    s = _FOOTREF_RE.sub("", s)
    if preset == CLAUDE_CODE:
        s = _CC_EXPAND_RE.sub("", s)
        s = _shorten_paths(s)
    s = _CITE_AFTER_PUNCT_RE.sub("", s)
    if many_cites:
        s = _CITE_AFTER_WORD_RE.sub("", s)
    s = _SUPERSCRIPT_CITE_RE.sub("", s)
    s = _emphasis(s)

    # Stashed values can hold stash tokens of their own (an escape inside
    # a code span); unwind until none are left.
    while "" in s:
        restored = _STASH_RE.sub(lambda m: kept[int(m.group(1))], s)
        if restored == s:
            break
        s = restored
    return s


# ----- 4. finish: sentence breaks and whitespace

_SPACE_RUN_RE = re.compile(r"[ \t]{2,}")
_BLANK_RUN_RE = re.compile(r"\n{3,}")
_CLOSERS = " \"'”’)]»"
_STOPS = ".!?:;,…—–-/"


def _with_stop(line: str) -> str:
    """End a line with a full stop so the voice pauses and the chunker
    splits there, unless it already ends in punctuation."""
    core = line.rstrip(_CLOSERS)
    if not core or core[-1] in _STOPS or not (core[-1].isalnum() or core[-1] in "%*"):
        return line
    return line.rstrip() + "."


def _finish(blocks: list[_Block]) -> str:
    kept = []
    for block in blocks:
        lines = [_SPACE_RUN_RE.sub(" ", ln).strip() for ln in block.lines]
        lines = [ln for ln in lines if ln]
        if lines:
            block.lines = lines
            kept.append(block)
    out: list[str] = []
    for idx, block in enumerate(kept):
        lines = list(block.lines)
        if idx + 1 < len(kept):
            lines[-1] = _with_stop(lines[-1])
        if out:
            out.append("\n\n" if block.gap_before else "\n")
        out.append("\n".join(lines))
    return _tidy("".join(out))


def _tidy(text: str) -> str:
    text = "\n".join(_SPACE_RUN_RE.sub(" ", ln).strip() for ln in text.split("\n"))
    return _BLANK_RUN_RE.sub("\n\n", text).strip()
