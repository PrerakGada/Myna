# Myna Daemon — HTTP API Contract (v1 + v2 additions)

**Purpose:** The single source of truth for the HTTP API between the Swift app, Hammerspoon, the CLI, and the Claude Code hook. Lane A (Swift) and Lane C (daemon refactor) must both conform to this doc. Changes here require orchestrator approval.

**Base URL:** `http://127.0.0.1:8766` (configurable via `~/.config/myna/config.json` → `daemon_port`)

**Auth:** None. The daemon binds to 127.0.0.1 only. No cross-origin requests accepted.

**Content type:** `application/json` for all bodies unless otherwise noted.

**Versioning:** v1 endpoints are unversioned (existing). v2 endpoints are prefixed `/v2/`. v1 endpoints remain forever-compatible to keep Hammerspoon working during the transition.

---

## 1. v1 endpoints (EXISTING — do not break)

These are exercised by the v1 Hammerspoon script and the v1 CLI. Lane C must NOT change their shape.

### `POST /speak`

Synthesize text (or extract from a URL) and play it through the daemon's internal `Player` (afplay).

**Request:**
```json
{
  "text": "string | null",
  "url":  "string | null",
  "mode": "full | summary",
  "voice": "string | null",
  "speed": 0.5,
  "source": "string | null"
}
```

**Behavior:**
- If `url` is set: extract article, optionally summarize, then speak.
- If `text` is set: optionally summarize, then speak.
- If both empty: `{"ok": false, "reason": "empty"}`.
- Extract failure: `{"ok": false, "reason": "extract_failed"}`.
- Success: `{"ok": true}`.

**Used by:** v1 Hammerspoon, v1 CLI.

### `POST /pause`, `POST /resume`, `POST /stop`

Control the daemon's internal `Player`. Returns `{"ok": true}`.

**Used by:** v1 Hammerspoon menu, v1 hotkeys.

### `POST /speed`

```json
{ "value": 0.5 }
```
Clamps to [0.5, 2.0]. Returns `{"ok": true, "speed": <clamped>}`.

### `GET /status`

```json
{
  "state": "idle | playing | paused | down",
  "now_playing": { "source": "...", "preview": "..." } | null,
  "speed": 1.0,
  "registry_count": 3,
  "engine": "up | down"
}
```

### `POST /announce`

```json
{ "session_id": "...", "label": "...", "text": "..." }
```
Adds to the silent registry of Claude Code outputs awaiting user playback. Returns `{"ok": true, "id": "<hex8>"}`.

### `GET /registry`

```json
{
  "items": [
    { "id": "abcd1234", "label": "ECS", "age_s": 12, "preview": "First 60 chars..." }
  ]
}
```

### `POST /play/{item_id}?mode=full|summary`

Pop the announced item and speak it. Returns `{"ok": true}` or `{"ok": false, "reason": "not_found"}`.

---

## 2. v2 endpoints (NEW — for the Swift app)

The Swift app does its own playback, so it needs raw audio bytes, not "fire-and-forget speak." These endpoints are additive — they don't change anything v1 sees.

### `POST /v2/synthesize` — streaming WAV bytes per chunk

**Purpose:** The Swift app sends text; the daemon returns one WAV per chunk as a multipart stream. The Swift app feeds buffers into `AVAudioEngine` for native playback control.

**Request:**
```json
{
  "text": "string (required, non-empty after trim)",
  "voice": "string (optional, defaults to config voice)",
  "speed": 1.0,
  "mode": "full | summary",
  "url": "string (optional, mutually exclusive with text)",
  "chunk_chars": 1500,
  "session_id": "string (optional; client UUID for cache scoping)",
  "bundle_id": "string (optional; frontmost app, for the voice wardrobe)",
  "source": "selection | clipboard | article | claude_code | replay | … (optional)",
  "prep": "auto | literal (optional, default auto)",
  "summary_style": "tldr | key_points | action_items | plain_english (optional; mode summary only)"
}
```

**Text prep.** Before chunking, the daemon turns the text into the words to
speak (`daemon/myna/speakable.py`): markdown syntax, fenced code, long inline
code, bare URLs and citation marks out, per a preset chosen by `source`
(`claude_code` also shortens file paths and drops diffs; `article`, and any
`url` read, also drops captions, ads and reference lists; anything else gets
the base pass). `prep: "literal"` reads the text as written. The response
header `X-Myna-Speakable` names what was applied
(`base | claude_code | article | literal`); `X-Chunk-Text` carries the cleaned
text. Text that is empty once cleaned is `400 empty`.

`summary_style` picks the kind of summary Ollama writes on the `mode: "summary"` path; missing or unknown means `tldr`. The app sends it only when it falls back to the daemon: when Apple Intelligence wrote the summary in the app, the request is a plain `mode: "full"` read of that summary and carries no style. Prompts: `daemon/myna/summarize.py`, mirrored word for word in `apps/macos/Sources/Summaries/SummaryPrompts.swift`.

**Response:** `Transfer-Encoding: chunked`, `Content-Type: multipart/mixed; boundary=mynachunk`

Each part has:
```
--mynachunk
Content-Type: audio/wav
X-Chunk-Index: 0
X-Chunk-Total-Estimate: 8
X-Chunk-Text: "First 200 chars of this chunk's text, URL-encoded"
X-Chunk-Text-Full: "The whole chunk's text, URL-encoded (added Sep 2026; optional for clients)"

<WAV bytes>
```

Final part:
```
--mynachunk
Content-Type: application/json

{ "ok": true, "chunks": 8, "session_id": "..." }
--mynachunk--
```

**Errors (returned as a single JSON body with HTTP error code):**
- `400`: `{"ok": false, "reason": "empty" | "both_text_and_url" | "neither_text_nor_url"}`
- `502`: `{"ok": false, "reason": "engine_down" | "engine_error", "detail": "..."}`
- `504`: `{"ok": false, "reason": "engine_timeout"}`
- `503` (summary mode only; top-level, not nested under `detail`): `{"ok": false, "reason": "ollama_not_running" | "ollama_not_installed" | "summary_model_missing" | "summary_timeout" | "summary_failed", "detail": "..."}`

**Used by:** Swift app.

**Why multipart and not WebSocket:** No browser involved. Plain HTTP chunked transfer is fewer moving parts, easier to test with `curl`, easier for `URLSession` to consume via `URLSession.bytes(for:)`. WebSocket would be over-engineered.

### `POST /v2/speakable` — the words a read would speak

Runs the same text prep as `/v2/synthesize` and returns the result, without
speaking. Deterministic: History shows a past read "as heard" by sending the
read's text, source and prep again.

```json
{"text": "## Done\n\nFixed `/Users/x/app.py:42`.", "source": "claude_code", "prep": "auto", "source_kind": null}
```
→
```json
{"ok": true, "text": "Done.\n\nFixed app.py line 42.", "changed": true, "preset": "claude_code"}
```

`source_kind` (optional) is a document's kind; `web`, `pdf` and `epub` get the
article preset. `changed` is false when only spacing differs. Errors:
`400 {"ok": false, "reason": "empty"}`, `413 input_too_long`, `422` for an
unknown `prep`.

### `/v2/pronunciations` — the pronunciation list

Word or phrase → respelling, applied after text prep on every read, summary,
render and `/v2/speakable` (also under `prep: literal`). Case-insensitive,
whole-word, longest first. The user's entries plus a starter list of tech
words (switchable as a whole or per entry). `GET` the list; `POST {word, say}`
adds; `PATCH /{id} {word?, say?, enabled?}`; `DELETE /{id}`;
`PATCH /starter {enabled}`; `PATCH /starter/{id} {enabled}`. Every answer is
the whole list: `{"starter_enabled", "entries": [{id, word, say, enabled}],
"starter": [{id, word, say, heard, enabled, overridden}]}`. Full reference:
`docs/api-contracts-daemon.md` § 7.

### `POST /v2/synthesize-summary` — convenience

Same as `/v2/synthesize` but pre-summarizes. Equivalent to `/v2/synthesize` with `mode: "summary"` — exposed separately for clarity and so the CLI/URL-scheme can target it without conditional JSON.

### `GET /v2/status` — richer status

**Purpose:** The Swift app polls this for the menu bar. Returns more than `/status` does.

```json
{
  "state": "idle | synthesizing | streaming | down",
  "engine": {
    "url": "http://127.0.0.1:8765",
    "status": "up | down",
    "model": "prince-canuma/Kokoro-82M",
    "last_check_age_s": 1.4
  },
  "daemon": {
    "version": "0.2.0",
    "uptime_s": 12345,
    "pid": 4444
  },
  "config": {
    "voice": "af_heart",
    "speed": 1.0,
    "lang_code": "a",
    "chunk_chars": 1500,
    "summary_model": "qwen3.5:4b"
  },
  "registry": {
    "count": 3,
    "items": [{ "id": "...", "label": "...", "age_s": 12, "preview": "..." }]
  },
  "v1_player": {
    "state": "idle | playing | paused",
    "now_playing": null
  }
}
```

Note: `v1_player` is included for diagnostics only. The Swift app ignores it; it owns its own playback state.

### `GET /v2/voices` — the active engine's voices, and the user's own it can speak

```json
{
  "voices": [
    { "id": "af_heart", "label": "Heart", "lang": "en", "default": true, "kind": "builtin",
      "group": "American English", "gender": "female", "grade": "A" },
    { "id": "bf_emma", "label": "Emma", "lang": "en", "default": false, "kind": "builtin",
      "group": "British English", "gender": "female", "grade": "B-" },
    { "id": "blend-3f9a1c20", "label": "Warm George", "lang": "en", "default": false, "kind": "blend",
      "group": "Your blends", "detail": "Blend of George ×3 + Heart ×1" }
  ],
  "active_engine": { "id": "kokoro", "name": "Kokoro", "can_clone": false, "can_blend": true }
}
```

**Behavior:** The list comes from the engine catalog (`myna.engines`) plus the user's voice store (`myna.voice_store`) — mlx-audio has no voice-list endpoint, so the engine is never asked. Kokoro lists its 41 voices in American/British English, Spanish, French, Hindi, Italian and Brazilian Portuguese (Japanese and Mandarin need G2P packages the engine venv lacks). Pocket TTS and Chatterbox add the user's clip voices (`kind: "clip"`); Kokoro adds blends (`kind: "blend"`). `active_engine.note` explains an engine with nothing to choose (Soprano). New fields are optional; old clients ignore them. If engine down: `{"voices": [], "engine": "down"}` — the happy path never carries `engine`.

**Kokoro language:** each synthesize sends the Kokoro pipeline the voice's own language (`bf_*` → `b`, `ef_*` → `e`…, a blend uses its first voice), not the config's single `lang_code`.

### The user's own voices — clips, blends, and the voice library

| Endpoint | Does | Errors |
|---|---|---|
| `POST /v2/voices/clips?name=` | Body: a PCM WAV (`audio/wav`), 5.5–30 s, ≤ 12 MB. Stores it and returns the new `Voice` (`clip-<hex>`), 201. Pocket is sent the file's path as its `voice`; Chatterbox gets it as `ref_audio`. | 400 `bad_audio` / `too_short` / `too_long` / `too_large` |
| `POST /v2/voices/blends` | `{name?, mix: [{voice, weight 1–4}]}`, 2–3 distinct Kokoro voices. Returns the `Voice` (`blend-<hex>`), 201. Kokoro is sent `"a,a,a,b"` for a 3:1 mix. | 400 `bad_blend` |
| `PATCH /v2/voices/custom/{id}` | `{name}` → the renamed `Voice`. | 404 `not_found` |
| `DELETE /v2/voices/custom/{id}` | Removes the voice (and its clip). Reads that still ask for it fall back like any foreign voice. `{ok: true}` | 404 `not_found` |
| `GET /v2/voices/library` | `{voices: [LibraryVoice], source}` — 113 labelled clips from Kyutai's tts-voices (VCTK accents, CC BY 4.0; a voice actor, CC BY 4.0; LibriVox narrators, CC0). `added_as` is set once the user has added one. | — |
| `GET /v2/voices/library/{id}/sample` | The original recording (downloaded once, pinned revision, cached in `~/Library/Caches/myna/voice_library/`). | 404, 502 `download_failed` |
| `POST /v2/voices/library/{id}` | Adds that clip as a clip voice (idempotent) and returns the `Voice`. | 404, 502 `download_failed` |

Store: `~/Library/Application Support/Myna/voices/` (`voices.json` + `clip-*.wav`). The engine shim caches the conditioning Chatterbox derives from each clip and restores its built-in voice for requests without one (upstream keeps the last clip's voice for good).

### `POST /v2/extract` — URL → article text (no speech)

```json
{ "url": "https://..." }
```

**Response:**
```json
{ "ok": true, "text": "...", "title": "...", "byline": "..." }
```
or
```json
{ "ok": false, "reason": "extract_failed" }
```

**Used by:** Swift app for the `read-chrome` flow (so the app can show a "Preview" sheet before playing).

### `POST /v2/summarize` — text → summary (no speech)

```json
{ "text": "...", "summary_style": "key_points" }
```

`summary_style` is optional (default `tldr`). Text too long for one Ollama call (16,000 characters; 9,000 for `plain_english`) is summarized in parts, then the parts' digests are summarized together, within a 180 s budget. Failures are the same `503` bodies as `/v2/synthesize` in summary mode.

**Response:**
```json
{ "ok": true, "summary": "..." }
```

**Used by:** the Summaries card's Try button, when Ollama is the backend.

### `GET /v2/summarize/status` — can the Ollama fallback run?

One probe of Ollama's `/api/tags` (1.5 s timeout), plus the style list.

```json
{
  "ok": true,
  "ollama": { "state": "ready | model_missing | not_running | not_installed", "model": "qwen3.5:4b", "url": "http://127.0.0.1:11434" },
  "styles": ["tldr", "key_points", "action_items", "plain_english"],
  "default_style": "tldr"
}
```

**Used by:** Swift app, to pick a summary backend before a read and for the Summaries card's status line.

### `GET /v2/health` — liveness probe

```json
{ "ok": true, "version": "0.2.0", "engine_up": true }
```

Fast (no engine call if cached). Used by Swift app's pre-speak health check.

### Voice engines — `/v2/engines`

The catalog of voice models Myna can speak with (`daemon/myna/engines.py`). All
run inside the one mlx-audio engine; switching changes the `model` sent on each
synthesize call. Fixture: `fixtures/engines-response.json`.

| Method + path | Does | Errors |
|---|---|---|
| `GET /v2/engines` | `{active, switching_to?, engines: [Engine]}` | — |
| `POST /v2/engines/{id}/install` | Starts a background download into the Hugging Face cache (via the engine venv). Returns the `Engine`; poll `GET /v2/engines` for `progress`. | 404 `unknown_engine`, 409 `no_engine_venv` |
| `POST /v2/engines/{id}/activate` | Loads the model, speaks a warm-up line, THEN saves `engine`/`model`/`voice` to config and unloads the previous model. Slow on a cold model (clients use a 300 s timeout). Returns `{ok, active, voice, load_s}`; the app sets its saved voice to `voice`. | 404, 409 `not_installed` / `switch_in_progress`, 502 `engine_error` (previous engine stays active), 503 `engine_down` |
| `DELETE /v2/engines/{id}` | Deletes the engine's files, following hub-store symlinks and keeping content other repos still link to. | 404, 409 `engine_active` / `cannot_remove` (Kokoro is the fallback) |

`Engine` = `{id, name, maker, tagline, description, repo, params, languages[], license, credit?, badge?, download_mb, sample_rate, native_speed, cloning, voices[{id,label}], default_voice, stats{first_word_s, stream_first_s?, speed_x, peak_memory_mb, word_error_pct, measured_on}, active, state (installed|downloading|failed|not_installed), progress?, downloaded_mb?, total_mb?, disk_mb?, error?}`.

Errors are FastAPI-nested: `{"detail": {"ok": false, "reason": "...", "detail": "..."}}`.

Voices: every synthesize resolves the requested voice against the active engine. A voice the engine lacks (the app sends its saved voice on every read) falls back to the voice last used on that engine, then the engine default. `GET /v2/voices` lists the active engine's voices. `GET /v2/status` adds `engine.id` + `engine.name`; `GET /v2/model/status` adds `engine_memory_mb` (physical footprint of the engine process) + `engine_pid`, and `model_loaded` now means the engine actually holds the active model.

---

## 3. Compatibility matrix

| Endpoint | v1 Hammerspoon | v1 CLI | v2 Swift app |
|---|---|---|---|
| `POST /speak` | ✅ | ✅ | ❌ (uses `/v2/synthesize`) |
| `POST /pause` `/resume` `/stop` `/speed` | ✅ | — | ❌ (Swift app owns playback) |
| `GET /status` | ✅ | — | ❌ (uses `/v2/status`) |
| `POST /announce` | — | — | — (Claude Code hook still posts) |
| `GET /registry` | ✅ | — | ✅ |
| `POST /play/{id}` | ✅ | — | rewritten: pop item and call `/v2/synthesize` internally |
| `POST /v2/synthesize` | — | — | ✅ |
| `POST /v2/synthesize-summary` | — | — | ✅ |
| `GET /v2/status` | — | — | ✅ |
| `GET /v2/voices` | — | — | ✅ |
| `POST /v2/extract` | — | — | ✅ |
| `POST /v2/summarize` | — | — | ✅ |
| `GET /v2/summarize/status` | — | — | ✅ |
| `GET /v2/health` | — | — | ✅ |

---

## 4. Swift-side type definitions (canonical)

Lane A workers implement these verbatim in `Sources/Network/DaemonTypes.swift`:

```swift
import Foundation

public enum DaemonState: String, Codable, Sendable {
    case idle, synthesizing, streaming, down
    case unknown
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = DaemonState(rawValue: s) ?? .unknown
    }
}

public struct EngineInfo: Codable, Sendable {
    public let url: String
    public let status: String   // "up" | "down"
    public let model: String
    public let lastCheckAgeS: Double

    enum CodingKeys: String, CodingKey {
        case url, status, model
        case lastCheckAgeS = "last_check_age_s"
    }
}

public struct DaemonInfo: Codable, Sendable {
    public let version: String
    public let uptimeS: Double
    public let pid: Int

    enum CodingKeys: String, CodingKey {
        case version, pid
        case uptimeS = "uptime_s"
    }
}

public struct DaemonConfig: Codable, Sendable {
    public let voice: String
    public let speed: Double
    public let langCode: String
    public let chunkChars: Int
    public let summaryModel: String

    enum CodingKeys: String, CodingKey {
        case voice, speed
        case langCode = "lang_code"
        case chunkChars = "chunk_chars"
        case summaryModel = "summary_model"
    }
}

public struct RegistryItem: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let ageS: Int
    public let preview: String

    enum CodingKeys: String, CodingKey {
        case id, label, preview
        case ageS = "age_s"
    }
}

public struct RegistryInfo: Codable, Sendable {
    public let count: Int
    public let items: [RegistryItem]
}

public struct DaemonStatus: Codable, Sendable {
    public let state: DaemonState
    public let engine: EngineInfo
    public let daemon: DaemonInfo
    public let config: DaemonConfig
    public let registry: RegistryInfo
}

public struct Voice: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let lang: String
    public let isDefault: Bool
    enum CodingKeys: String, CodingKey {
        case id, label, lang
        case isDefault = "default"
    }
}

public struct VoicesResponse: Codable, Sendable {
    public let voices: [Voice]
}

public enum SynthesizeMode: String, Codable, Sendable {
    case full, summary
}

public struct SynthesizeRequest: Codable, Sendable {
    public var text: String?
    public var url: String?
    public var voice: String?
    public var speed: Double
    public var mode: SynthesizeMode
    public var chunkChars: Int?
    public var sessionId: String?

    enum CodingKeys: String, CodingKey {
        case text, url, voice, speed, mode
        case chunkChars = "chunk_chars"
        case sessionId = "session_id"
    }
}

public struct SynthesizedChunk: Sendable {
    public let index: Int
    public let totalEstimate: Int
    public let textPreview: String
    public let wavData: Data
}

public enum DaemonError: Error, Sendable {
    case empty
    case bothTextAndURL
    case neitherTextNorURL
    case engineDown
    case engineError(String)
    case engineTimeout
    case extractFailed
    case notFound
    case http(Int, String)
    case decode(String)
    case transport(Error)
}
```

---

## 5. Daemon-side handler signatures (canonical)

Lane C workers implement these in `daemon/myna/app.py`:

```python
@app.post("/v2/synthesize")
async def v2_synthesize(req: V2SynthesizeReq) -> StreamingResponse: ...

@app.post("/v2/synthesize-summary")
async def v2_synthesize_summary(req: V2SynthesizeReq) -> StreamingResponse: ...

@app.get("/v2/status")
def v2_status() -> V2Status: ...

@app.get("/v2/voices")
async def v2_voices() -> V2Voices: ...

@app.post("/v2/extract")
async def v2_extract(req: V2ExtractReq) -> V2ExtractResp: ...

@app.post("/v2/summarize")
async def v2_summarize(req: V2SummarizeReq) -> V2SummarizeResp: ...

@app.get("/v2/health")
def v2_health() -> V2Health: ...
```

All `V2*` Pydantic models live in `daemon/myna/v2_types.py` (NEW file Lane C creates).

---

## 6. Test fixtures (shared between lanes)

A `tests/fixtures/` directory holds canonical request/response examples that both Swift tests and daemon tests load. Keeps the two sides honest.

```
docs/native-app/fixtures/
├── synthesize-request.json
├── status-response.json
├── voices-response.json
├── extract-request.json
├── extract-response.json
└── engines-response.json
```

Lane A tests decode these into Swift types. Lane C tests assert the daemon produces these shapes. If a fixture changes, both sides fail until updated.

---

## 7. Change-control

Any change to this doc requires:
1. Orchestrator update of the doc with a `## Changelog` entry at the bottom
2. Bumped fixture if shape changes
3. Both Lane A and Lane C test suites re-run

Workers cannot modify this doc.

---

## Changelog

- **2026-05-25**: Initial draft. v1 endpoints documented as-is. v2 endpoints specified for Swift app integration.
- **2026-09-29**: Voice-engine catalog — `/v2/engines` list/install/activate/remove; `engine.id`/`engine.name` on `/v2/status`; `engine_memory_mb`/`engine_pid` on `/v2/model/status`; new fixture `engines-response.json`.
- **2026-09-30**: Pronunciations — `/v2/pronunciations` (list, add, edit, delete, starter switches), applied after text prep everywhere, including under `prep: literal`.
- **2026-09-30**: Text prep — optional `source` and `prep` on `/v2/synthesize` (and v1 `/speak`), `X-Myna-Speakable` response header, new `POST /v2/speakable`; `synthesize-request.json` fixture gains `source` + `prep`.
- **2026-09-29**: Voices — `/v2/voices` lists every Kokoro voice (41) with `kind`/`group`/`gender`/`grade`/`detail`/`credit` and an `active_engine` block (`can_clone`, `can_blend`, `note`); per-voice Kokoro `lang_code`; the user's own voices: `/v2/voices/clips`, `/v2/voices/blends`, `/v2/voices/custom/{id}` (PATCH/DELETE), `/v2/voices/library` (+ `/{id}/sample`, POST `/{id}`); `blending` on each `/v2/engines` entry.
