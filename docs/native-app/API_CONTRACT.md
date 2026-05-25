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
  "session_id": "string (optional; client UUID for cache scoping)"
}
```

**Response:** `Transfer-Encoding: chunked`, `Content-Type: multipart/mixed; boundary=mynachunk`

Each part has:
```
--mynachunk
Content-Type: audio/wav
X-Chunk-Index: 0
X-Chunk-Total-Estimate: 8
X-Chunk-Text: "First 200 chars of this chunk's text, URL-encoded"

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

**Used by:** Swift app.

**Why multipart and not WebSocket:** No browser involved. Plain HTTP chunked transfer is fewer moving parts, easier to test with `curl`, easier for `URLSession` to consume via `URLSession.bytes(for:)`. WebSocket would be over-engineered.

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

### `GET /v2/voices` — list available voices

```json
{
  "voices": [
    { "id": "af_heart",  "label": "Heart (female)",  "lang": "en", "default": true  },
    { "id": "af_bella",  "label": "Bella (female)",  "lang": "en", "default": false },
    { "id": "am_michael","label": "Michael (male)",  "lang": "en", "default": false }
    // … queried from Kokoro on first call, cached
  ]
}
```

**Behavior:** First call queries Kokoro `/v1/models` or its voice list endpoint, caches for 5 minutes. If engine down: `{"voices": [], "engine": "down"}`.

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
{ "text": "..." }
```

**Response:**
```json
{ "ok": true, "summary": "..." }
```

**Used by:** Swift app's summary preview.

### `GET /v2/health` — liveness probe

```json
{ "ok": true, "version": "0.2.0", "engine_up": true }
```

Fast (no engine call if cached). Used by Swift app's pre-speak health check.

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
└── extract-response.json
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
