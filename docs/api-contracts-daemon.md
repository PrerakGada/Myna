# Myna Daemon — HTTP API Reference

*Lane B exhaustive scan • Source of truth: `daemon/myna/app.py`*

**Base URL:** `http://127.0.0.1:8766` (configurable via `~/.config/myna/config.json` → `daemon_port`)
**Auth:** none from this Mac. Local-network access is off by default; when the API pane turns it on, other devices need a key and reach `/v1/*` only (§ 6).
**Default Content-Type:** `application/json` (except `/v2/synthesize` which is `multipart/mixed`).
**Daemon version:** `0.2.0` (`daemon/myna/__init__.py:1`).

Two surfaces share one app:

- **v1**: unversioned, used by Hammerspoon v1 and the v1 CLI. Mutates the daemon's internal `Player`.
- **v2**: prefixed `/v2/`, used by the Swift app. Returns raw bytes / status; never plays audio.

Section 4 lists **spec drift** between this code and `docs/native-app/API_CONTRACT.md`.

---

## 1. v2 Endpoints

### `POST /v2/synthesize`

Handler: `app.py:415-417` → `_v2_synthesize_response` (`app.py:312-411`).
Stream raw WAVs back to the Swift app via `multipart/mixed`.

**Request body — `V2SynthesizeReq` (`v2_types.py:12-19`):**

| Field | Type | Required | Default | Validation |
|---|---|---|---|---|
| `text` | `string \| null` | conditional | `null` | mutually exclusive with `url`; one of `text`/`url` must be set |
| `url` | `string \| null` | conditional | `null` | mutually exclusive with `text`; no scheme validation here (only `/v2/extract` validates) |
| `voice` | `string \| null` | no | `cfg["voice"]` (default `af_heart`) | Kokoro voice id; not validated server-side |
| `speed` | `float` | no | `1.0` | **clamped** to `[0.5, 2.0]` (`app.py:338`) |
| `mode` | `"full" \| "summary"` | no | `"full"` | enforced via `Literal` |
| `chunk_chars` | `int \| null` | no | `cfg["chunk_chars"]` (default 1500) | no clamp (see § 4) |
| `session_id` | `string \| null` | no | server-generated `uuid4().hex` | echoed back in the final part |
| `bundle_id` | `string \| null` | no | `null` | frontmost app; picks the voice-wardrobe voice |
| `source` | `string \| null` | no | `null` | where the text came from (`selection`, `clipboard`, `article`, `claude_code`, `replay`, …); picks the text-prep preset (§ 7). Unknown values get the base pass. |
| `prep` | `"auto" \| "literal"` | no | `"auto"` | `literal` reads the text exactly as written (§ 7) |
| `summary_style` | `string \| null` | no | `"tldr"` | `mode: "summary"` only: `tldr` / `key_points` / `action_items` / `plain_english`; unknown reads as `tldr` (`summarize.normalize_style`) |

**Response — happy path (HTTP 200):**

- `Content-Type: multipart/mixed; boundary=mynachunk`
- `Transfer-Encoding: chunked`
- One audio part per chunk:

  ```
  --mynachunk
  Content-Type: audio/wav
  X-Chunk-Index: 0
  X-Chunk-Total-Estimate: 8
  X-Chunk-Text: First%20200%20chars%20URL-encoded
  X-Chunk-Text-Full: The%20whole%20chunk%20URL-encoded
  X-Chunk-Timing: model
  X-Chunk-Words: [[275,625,0,6],[625,975,7,12],...]

  <WAV bytes>
  ```

- One closing JSON part:

  ```
  --mynachunk
  Content-Type: application/json

  {"ok": true, "chunks": 8, "session_id": "abc-123"}
  --mynachunk--
  ```

`X-Chunk-Text` is URL-encoded via `urllib.parse.quote(preview[:200], safe="")` (`app.py:362`).
It is the cleaned text (§ 7), so karaoke shows what is spoken. The response
also carries `X-Myna-Speakable: base | claude_code | article | literal`, the
preset that was applied.

`X-Chunk-Text-Full` is the same encoding of the whole chunk, uncapped. It is the text the engine was
asked to speak (after any daemon-side cleanup), so the app's sentence transcript shows what was heard.
Additive since Sep 2026: clients that don't know it ignore it; the app falls back to `X-Chunk-Text`.

`X-Chunk-Words` says when each word of the chunk is spoken, for the pill's live captions:
`[[start_ms, end_ms, at_start, at_end], ...]`, ms from the start of this part's WAV, `at` a range into
`X-Chunk-Text-Full` in UTF-16 code units. `X-Chunk-Timing` is `model` (Kokoro's own duration predictor,
via the engine shim) or `estimated` (any other engine or language). Built by `reading.header_words`.
Additive since 6 Oct 2026; the app shows unlit sentences without it.

**Error responses (all single JSON body, NOT multipart):**

| Status | Body | When |
|---|---|---|
| 400 | `{"detail": {"ok": false, "reason": "neither_text_nor_url"}}` | both `text` and `url` are absent (`app.py:277-281`) |
| 400 | `{"detail": {"ok": false, "reason": "both_text_and_url"}}` | both `text` and `url` provided (`app.py:269-273`) |
| 400 | `{"detail": {"ok": false, "reason": "empty"}}` | text trims to empty (`app.py:295-299`), is empty once cleaned (§ 7), or chunker returns `[]` (`app.py:327-331`) |
| 400 | `{"detail": {"ok": false, "reason": "extract_failed"}}` | `app.state.extract(url)` returned None/empty (`app.py:285-290`) |
| 502 | `{"ok": false, "reason": "engine_down"}` | engine health check failed (`app.py:317-321`) — note flat body, not wrapped in `detail` |
| 502 | `{"ok": false, "reason": "engine_error", "detail": "<exception str>"}` | first-chunk synthesis raised (`app.py:353-357`) |

**Status notes:**

- Mid-stream chunk failure does **NOT** error the response. The stream closes cleanly and the final JSON part reports the actual chunk count (`app.py:398-406`). The client sees `ok:true` even though chunks were lost. See `architecture-daemon.md` § 18 #1.
- `text="   "` (whitespace) is rejected, but `text=null` + `url=null` is `neither_text_nor_url`; these are distinct codes.

**Curl example:**

```bash
curl -N -X POST http://127.0.0.1:8766/v2/synthesize \
  -H 'Content-Type: application/json' \
  -d '{"text": "Hello there. This is Myna.", "speed": 1.25, "mode": "full"}'
```

(`-N` disables curl buffering so you see the streamed multipart in real time.)

**Request example** (`docs/native-app/fixtures/synthesize-request.json`):

```json
{
  "text": "Hello there. This is a test of the Myna v2 synthesize endpoint.",
  "voice": "af_heart",
  "speed": 1.0,
  "mode": "full",
  "chunk_chars": 1500,
  "session_id": "1f3b2c50-8b4f-4d2c-9c5e-2f5a6f1b3d2c",
  "source": "selection",
  "prep": "auto"
}
```

---

### `POST /v2/synthesize-summary`

Handler: `app.py:419-421`. Identical to `/v2/synthesize` but forces `mode="summary"` regardless of what the client sends. Used by the Swift summary-shortcut path so the CLI/URL scheme can hit one route without conditional JSON.

Request body, response, and errors are identical to `/v2/synthesize` (just always summary).

---

### `GET /v2/status`

Handler: `app.py:423-456`. Returns a full state snapshot for the Swift menu bar.

**Response — `V2Status` (HTTP 200):**

```json
{
  "state": "idle",
  "engine": {
    "url": "http://127.0.0.1:8765",
    "status": "up",
    "model": "prince-canuma/Kokoro-82M",
    "last_check_age_s": 1.4
  },
  "daemon": {
    "version": "0.2.0",
    "uptime_s": 12345.6,
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
    "count": 1,
    "items": [
      {"id": "abcd1234", "label": "ECS", "age_s": 12, "preview": "Here is the first sixty characters of an announced message."}
    ]
  },
  "v1_player": {"state": "idle", "now_playing": null}
}
```

**Field notes:**

- `state` (`app.py:429`) is **only ever** `"down"` (engine cached as down) or `"idle"` (engine up). The other documented states `"synthesizing"` and `"streaming"` (per `API_CONTRACT.md:154`) are never emitted. See § 4 below.
- `engine.last_check_age_s` is seconds since last engine probe (cached for 1.0s by `_check_engine_cached`).
- `daemon.uptime_s` is `time.time() - app.state.started_at` (`app.py:438`).
- `v1_player.now_playing` is whatever `meta` was passed to `Player.play()` — `{"source": <str>, "preview": <60 chars>}` or `null`.
- `registry.items[*].preview` is `text[:60]`. `age_s` is integer seconds.

Errors: no error path; `_check_engine_cached` swallows exceptions and returns `False`.

**Curl example:**

```bash
curl http://127.0.0.1:8766/v2/status | jq
```

---

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
---

### `POST /v2/extract`

Handler: `app.py:478-511`.

**Request — `V2ExtractReq` (`v2_types.py:22-23`):**

| Field | Type | Required | Validation |
|---|---|---|---|
| `url` | `string` | yes | must start with `http://` or `https://` (`app.py:489-493`) |

**Response — `V2ExtractResp` (`v2_types.py:26-31`):**

Success (HTTP 200):

```json
{"ok": true, "text": "Lorem ipsum...", "title": "Lorem Ipsum: The Article", "byline": "Cicero"}
```

If the underlying `extract` returns a plain string, only `{ok, text}` is emitted (no null leaks):

```json
{"ok": true, "text": "Lorem ipsum..."}
```

Failure (HTTP 200, **not 4xx** — the URL was valid, the extraction just failed):

```json
{"ok": false, "reason": "extract_failed"}
```

URL validation failure (HTTP 400):

```json
{"detail": {"ok": false, "reason": "invalid_url"}}
```

**Key discipline**: `response_model_exclude_none=True` (`app.py:478-482`). Success bodies never carry null `title`/`byline`/`reason`; failure bodies never carry null `text`/`title`/`byline`. Pinned by `test_v2_audit_fixes.py:38-68`.

**Curl example:**

```bash
curl -X POST http://127.0.0.1:8766/v2/extract \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com/article"}'
```

---

### `POST /v2/summarize`

Handler: `app.py:513-534`.

**Request — `V2SummarizeReq` (`v2_types.py:34-35`):**

| Field | Type | Required | Validation |
|---|---|---|---|
| `text` | `string` | yes | trimmed; rejected if empty |
| `summary_style` | `string \| null` | no | as on `/v2/synthesize`; default `tldr` |

**Response — `V2SummarizeResp` (`v2_types.py:38-41`):**

Success (HTTP 200):

```json
{"ok": true, "summary": "Short spoken summary, in the requested style."}
```

Empty text (HTTP 400):

```json
{"detail": {"ok": false, "reason": "empty"}}
```

Summary failures raise `summarize.SummaryUnavailable`, which `summary_routes.py` turns into HTTP 503 with a top-level body `{"ok": false, "reason", "detail"}` (here and on `/v2/synthesize` in summary mode). Reasons: `ollama_not_running`, `ollama_not_installed`, `summary_model_missing` (Ollama answered 404 for `summary_model`), `summary_timeout`, `summary_failed`.

Every Ollama call sets `options.num_ctx` to 8192: without it Ollama silently drops the start of an over-long prompt, which is where the instructions are. Text over 16,000 characters (9,000 for `plain_english`) is summarized in parts and the digests are then summarized in the style (map-reduce); `plain_english` rewrites each part and joins them instead. The whole job has a 180 s budget.

`response_model_exclude_none=True` keeps `reason: null` out of success bodies (`app.py:513-517`). Pinned by `test_v2_audit_fixes.py:71-78`.

**Curl example:**

```bash
curl -X POST http://127.0.0.1:8766/v2/summarize \
  -H 'Content-Type: application/json' \
  -d '{"text":"long article body to summarise..."}'
```

---

### `GET /v2/summarize/status`

Handler: `summary_routes.py` (registered from `create_app`). One GET to Ollama's `/api/tags` with a 1.5 s timeout; tests replace `app.state.ollama_status`.

```json
{"ok": true, "ollama": {"state": "model_missing", "model": "qwen3.5:4b", "url": "http://127.0.0.1:11434"},
 "styles": ["tldr", "key_points", "action_items", "plain_english"], "default_style": "tldr"}
```

`state`: `ready`, `model_missing` (running, `summary_model` not pulled), `not_running` (an Ollama binary or app exists), `not_installed`.

---

### `GET /v2/health`

Handler: `app.py:536-542`.

**Response — `V2Health` (HTTP 200):**

```json
{"ok": true, "version": "0.2.0", "engine_up": true}
```

Always returns HTTP 200; `ok` is always `true`. `engine_up` uses the 1s cache.

**Curl example:**

```bash
curl http://127.0.0.1:8766/v2/health
```

---

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

## 2. v1 Endpoints

These exist for Hammerspoon, the v1 CLI, and the CC Stop hook. Lane C must not change their shape.

### `POST /speak`

Handler: `app.py:150-152` → `_speak` (`app.py:123-146`).

**Request — `SpeakReq` (`app.py:45-51`):**

| Field | Type | Required | Default |
|---|---|---|---|
| `text` | `string \| null` | conditional | `null` |
| `url` | `string \| null` | conditional | `null` |
| `mode` | `string` | no | `"full"` |
| `voice` | `string \| null` | no | `null` → fall back to `cfg["voice"]` |
| `speed` | `float \| null` | no | `null` → fall back to `app.state.speed` |
| `source` | `string \| null` | no | `null` → falls back to `"speak"` in player meta; `cc:<project>` gets the Claude Code text preset |
| `prep` | `string \| null` | no | `null` → `"auto"`; `"literal"` reads as written (§ 7) |

No mutual-exclusion check — if both `text` and `url` are given, `url` wins (extraction overwrites text).

**Response (HTTP 200):**

- `{"ok": true, "id": "r-…"}` on success. `id` names the read in `GET /reading` and `/reading/events` (added 6 Oct 2026; older callers ignore it).
- `{"ok": false, "reason": "empty"}` if text trims empty.
- `{"ok": false, "reason": "extract_failed"}` if URL fetch/extract returns empty.

No 4xx — v1 always returns 200 with an `ok` flag.

---

### `POST /announce`

Handler: `app.py:154-157`. Used by the CC Stop hook (`hooks/myna-cc-announce.py`).

**Request — `AnnounceReq` (`app.py:54-57`):**

| Field | Type | Required |
|---|---|---|
| `session_id` | `string` | yes |
| `label` | `string` | yes (typically `basename(cwd)`) |
| `text` | `string` | yes (truncated by caller to 8000 chars) |

**Response:** `{"ok": true, "id": "abcd1234"}` — `id` is an 8-hex unique key.

---

### `GET /registry`

Handler: `app.py:159-161`.

**Response:**

```json
{
  "items": [
    {"id": "abcd1234", "label": "ECS", "age_s": 12, "preview": "first 60 chars..."}
  ]
}
```

Always HTTP 200. `preview` is `text[:60]`. Items past TTL (30 min) or cap (10) are pruned before listing.

---

### `POST /play/{item_id}`

Handler: `app.py:163-168`. Path param `item_id` (8-hex), query param `?mode=full|summary` (default `full`).

Pops the registry item and pipes it to `_speak`. Returns whatever `_speak` returns, or `{"ok": false, "reason": "not_found"}` if the id is unknown.

---

### `POST /pause`, `POST /resume`, `POST /stop`

Handlers: `app.py:170-183`. No body. Always `{"ok": true}`. Forwards to `Player.pause / resume / stop`. Idempotent — `pause` on idle is a no-op (state stays idle).

---

### `POST /speed`

Handler: `app.py:185-188`.

**Request — `SpeedReq` (`app.py:60-61`):** `{"value": 1.5}`.

**Response:** `{"ok": true, "speed": <clamped>}`. Clamped to `[0.5, 2.0]` (`app.py:187`).

Mutates `app.state.speed` — this is the v1 global speed used by future `/speak` calls when `req.speed` is null. **Does not** affect `/v2/synthesize` (v2 takes its `speed` from the request only).

---

### `GET /status`

Handler: `app.py:190-199`.

**Response:**

```json
{
  "state": "idle",
  "now_playing": null,
  "speed": 1.0,
  "registry_count": 3,
  "engine": "up"
}
```

`state` ∈ `{idle, playing, paused}` (player state — no `down` here; engine status is a separate field).
`engine` ∈ `{up, down}`. **Not cached** — every `/status` call hits Kokoro fresh, unlike `/v2/status` which uses the 1s cache. (Acceptable because v1 callers poll less often.)

---

### `GET /reading` and `GET /reading/events` — the word being read

Module: `myna/reading.py` (its docstring is the full contract). Added 6 Oct 2026 for the Claude Code mod's word highlight (`~/.claude/mods/myna-play`).

Follows reads on the v1 player (`POST /speak`, `/play/{id}`) word by word. Kokoro English voices give real per-word times (the engine shim keeps the duration predictor's output and serves it at the engine's `GET /myna/word-timings/{key}`); every other engine and language gets an estimate per chunk. Each chunk says which (`timing`: `model` | `estimated`).

Every word carries `start`/`end` (ms from its chunk's start) and two ranges, in UTF-16 code units (what JavaScript and NSString count; an emoji is two): `src` into `text`, exactly what the client sent (null when cleanup added the word, or for URL and summary-mode reads), and `at` into `spoken`, the cleaned text actually read.

`GET /reading` → `{"ok": true, "reading": null | {id, text, spoken, voice, speed, state, reason, chunk, position_ms, word, chunks: [{index, timing, duration_ms, words}]}}`. `state` ∈ `{preparing, playing, paused, ended}`.

`GET /reading/events` → `text/event-stream`, open until the client leaves or the daemon stops. First frame `snapshot` (`{reading}` as above), then `start`, `chunk` (a chunk began playing, with its words), `word`, `pause`, `resume`, `end` (`reason` ∈ `finished, stopped, replaced, error`). A `: ping` comment every ~15 s while quiet. The clock is afplay's start; afplay's own start-up isn't measured, so a word can light a few tens of ms early, never late.

```bash
curl -N http://127.0.0.1:8766/reading/events
```

Not on the Mac app's player: `/v2/synthesize` reads still drive the old v0.2 karaoke sidecar emitter only.

---

## 3. The CC Stop Hook (not part of the daemon, but relevant)

`hooks/myna-cc-announce.py` (83 lines) is registered by `install.sh:43-61` as a Claude Code Stop hook. On every CC session end:

1. Reads stdin (JSON from CC).
2. Tails the transcript file at `data["transcript_path"]`, extracts the **last** assistant turn (`_last_assistant_text` walks the jsonl).
3. Joins all `{type:"text"}` content blocks; truncates to 8000 chars.
4. Labels with `basename(data["cwd"])` (e.g. `myna`, `dpsca-site`).
5. Posts to `POST http://127.0.0.1:${MYNA_PORT:-8766}/announce` with 1.5s timeout, **silently swallows all errors**.

The CC hook never blocks the session and never plays audio — only registers.

---

## 4. Spec Drift (code ↔ `API_CONTRACT.md` ↔ `DaemonTypes.swift`)

Catalogued by reading `app.py` and the contract side by side. Anything not listed here is in lockstep.

### 4.1 `/v2/status.state` enum

- **Contract** (`API_CONTRACT.md:154`): `"idle | synthesizing | streaming | down"`.
- **Swift** (`DaemonTypes.swift:5-16`): four cases plus `.unknown` fallback.
- **Daemon** (`app.py:429`): only emits `"idle"` or `"down"`.

Two enum cases are unreachable. The Swift side handles it (falls back to `.unknown`), but the menu bar can't distinguish "engine up, not doing anything" from "engine up, mid-stream right now." Fixing requires the daemon to track in-flight `/v2/synthesize` calls (simple counter on `app.state`).

### 4.2 `VoicesResponse.engine`

- **Contract** (`API_CONTRACT.md:351-353`): `VoicesResponse` declared as `{ voices: [Voice] }` — `engine` field is *not* listed in the canonical Swift declaration.
- **Swift actual** (`DaemonTypes.swift:155-163`): includes `public let engine: String?` (optional).
- **Daemon** (`app.py:466-476`): emits `engine: "down"` only when down, omits otherwise.

This is a contract update that didn't make it back into the doc — code and Swift agree, doc lags. Either fix the doc or remove the field. Code-wise it's right; the contract MD needs a refresh.

### 4.3 `DaemonError.transport(Error)` vs `DaemonError.transport(String)`

- **Contract** (`API_CONTRACT.md:393`): `case transport(Error)`.
- **Swift actual** (`DaemonTypes.swift:338`): `case transport(String)`.

Lane A changed `Error` → `String` (probably for `Equatable` conformance — see `DaemonTypes.swift:341-364`). Contract MD never caught up. Cosmetic from the daemon's perspective, but the contract MD is now lying.

### 4.4 `DaemonError.invalidURL(String)` is new

- **Contract** (`API_CONTRACT.md:382-394`): no `invalidURL` case.
- **Swift actual** (`DaemonTypes.swift:339`): `case invalidURL(String)` exists.

Added on the Swift side to handle the `/v2/extract` 400 `invalid_url` reason. Contract MD missing.

### 4.5 `/v2/synthesize` errors `504 engine_timeout` not implemented

- **Contract** (`API_CONTRACT.md:138`): documents `504 {ok:false, reason:"engine_timeout"}`.
- **Daemon** (`app.py:344-357`): only ever emits 502 for engine errors. A real timeout (`httpx.TimeoutException`) gets caught as `Exception` and reported as `engine_error` with the timeout exception's `str(exc)` in `detail`.

Tightening: catch `httpx.TimeoutException` separately and emit 504 with the documented body.

### 4.6 `_v2_synthesize_response` declared `async` in contract, written as sync

- **Contract** (`API_CONTRACT.md:404-405`): `async def v2_synthesize(...)`.
- **Daemon** (`app.py:415-417`): sync `def v2_synthesize(...)`.

This is fine — FastAPI runs sync handlers in a threadpool, and the streaming generator is sync too. Contract MD is stylistic, not enforceable.

### 4.7 Mid-stream chunk failure surfaces as `ok:true`

Not really "drift" but a behavior the contract leaves ambiguous. The contract says "stream returns one part per chunk + final summary." It doesn't say what happens if chunk N of M fails mid-stream. The daemon (`app.py:398-406`) silently truncates and emits `ok:true, chunks:<partial>`. Either the contract should mandate `ok:false, reason:"partial_engine_failure"` and the daemon should follow, or the contract should explicitly bless the current behavior.

### 4.8 `V2SynthesizeReq.chunk_chars` has no minimum

- **Daemon** (`v2_types.py:18`): `chunk_chars: Optional[int] = None`. No validator.
- **Risk**: `chunk_chars=0` would loop in `chunking.chunk_text` (`chunking.py:23-25`). Should be `Field(ge=100)` or similar.

### 4.9 v1 `POST /speak` accepts any URL scheme, v2 `POST /v2/extract` does not

- **Daemon v1** (`app.py:125`): forwards any `url` straight to `trafilatura.fetch_url` (which accepts `http(s)://` in practice but doesn't reject `file://` upfront).
- **Daemon v2** (`app.py:489-493`): rejects anything not `http://` / `https://`.

Asymmetric on purpose — v1 left lax to keep Hammerspoon callers happy. Document the asymmetry; don't fix it.

---

## 5. Quick-reference cheat sheet

| Method | Path | Body type | Returns | Purpose |
|---|---|---|---|---|
| POST | `/speak` | `SpeakReq` | JSON `{ok, id}` | v1 speak via internal Player |
| POST | `/announce` | `AnnounceReq` | JSON `{ok, id}` | register a CC turn |
| GET | `/registry` | — | JSON `{items}` | list pending CC items |
| POST | `/play/{id}?mode=` | — | JSON `{ok}` | pop + speak |
| POST | `/pause` | — | JSON `{ok}` | SIGSTOP afplay |
| POST | `/resume` | — | JSON `{ok}` | SIGCONT afplay |
| POST | `/stop` | — | JSON `{ok}` | kill afplay |
| POST | `/speed` | `SpeedReq` | JSON `{ok, speed}` | set global speed |
| GET | `/status` | — | JSON (5 keys) | v1 status |
| GET | `/reading` | — | JSON `{ok, reading}` | the v1 read, word by word |
| GET | `/reading/events` | — | `text/event-stream` | the same, pushed |
| POST | `/v2/synthesize` | `V2SynthesizeReq` | `multipart/mixed` | stream WAV per chunk |
| POST | `/v2/synthesize-summary` | `V2SynthesizeReq` | `multipart/mixed` | as above, force summary |
| GET | `/v2/status` | — | `V2Status` JSON | rich status for Swift menu |
| GET | `/v2/voices` | — | `V2Voices` JSON | active engine's voices + the user's own, from the catalog |
| POST/PATCH/DELETE | `/v2/voices/clips`, `/blends`, `/custom/{id}` | WAV / `V2BlendReq` / `V2VoiceRenameReq` | `V2Voice` | the user's own voices |
| GET/POST | `/v2/voices/library[/{id}[/sample]]` | — | `V2Library` / WAV / `V2Voice` | voice library of clips |
| POST | `/v2/extract` | `V2ExtractReq` | `V2ExtractResp` | URL → article text |
| POST | `/v2/summarize` | `V2SummarizeReq` | `V2SummarizeResp` | text → spoken summary |
| GET | `/v2/summarize/status` | — | `V2SummaryStatus` | can the Ollama fallback run (`summary_routes.py`) |
| GET | `/v2/health` | — | `V2Health` | fast liveness probe |
| POST | `/v2/speakable` | `V2SpeakableReq` | `V2SpeakableResp` | text → the words a read would speak (§ 7) |
| GET/POST/PATCH/DELETE | `/v2/pronunciations[/starter[/{id}]\|/{id}]` | JSON | the whole list | pronunciation list (§ 7) |

---

## 6. Render API

Finished audio files out of the daemon, as opposed to `/v2/synthesize`, which
streams a read into the app's player. None of these touch the state machine,
karaoke, the pill, History or the remembered voice. **Full contract:
[`native-app/RENDER_API.md`](native-app/RENDER_API.md)**; code in
`daemon/myna/render_routes.py`, `render.py`, `render_jobs.py`, `encode.py`,
`api_access.py`.

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/audio/speech` | OpenAI-compatible text → audio bytes (mp3 opus aac flac wav pcm m4a) |
| GET | `/v1/models` | OpenAI model list: installed engines + `tts-1`-style aliases |
| GET | `/v1/audio/voices` | active engine's voices + OpenAI voice-name mapping |
| POST / GET | `/v2/renders` | create / list background render jobs (library in `~/Library/Application Support/Myna/renders/`) |
| GET | `/v2/renders/{id}`, `/v2/renders/{id}/audio` | job status, finished file |
| POST / DELETE | `/v2/renders/{id}/cancel`, `/v2/renders/{id}` | cancel, remove |
| GET | `/v2/formats` | which formats this Mac can encode (afconvert / ffmpeg / lame) |
| POST | `/v2/transcode?format=` | re-encode a WAV |
| GET / POST | `/v2/api/settings` | LAN access, API key; turning LAN on or off rebinds the daemon |
| GET | `/v2/api/log` | last 200 `/v1/*` and render requests (no text, only its length) |

`/v1/*` errors use OpenAI's `{"error": {...}}`; `/v2/*` keeps
`{"ok": false, "reason", "detail"}`. The Host-header check (DNS-rebinding
defence) moved from Starlette's `TrustedHostMiddleware` into
`api_access.AccessMiddleware`, unchanged for callers on this Mac.

---

## 7. Text prep (`myna/speakable.py`)

Every path that speaks runs the text through one pure function first,
**before chunking**, so chunks end on real sentences: `/v2/synthesize` and
`/v2/synthesize-summary` (a summary is cleaned after it is written), v1
`/speak`, `/play/{id}`, `/v2/registry/play/{id}`, `/v1/audio/speech` and
`/v2/renders`. `/v2/summarize` and `/v2/extract` return text for display and
are not cleaned.

| Preset | Who gets it | What it does |
|---|---|---|
| base | everything not below (selection, clipboard, replay, api, playground, studio text) | markdown syntax out, words kept (emphasis, headings, bullets, quotes, `[text](url)`); fenced code → "Code block skipped."; inline code read when short, else "a code snippet"; bare URLs → the site name (`github.com`, `localhost port 8766`); citation marks `[12]`, `[1, 3]`, `[citation needed]`, `[^1]` out; tables → one sentence per row ("Header: cell; Header: cell."); a full stop at the end of structural lines; whitespace collapsed. Emoji are left alone. |
| claude_code | `source: claude_code`, `cc:<project>`, v1 `/announce` items | base, plus: code blocks skipped silently; file paths → file name (`/Users/x/app.py:42` → "app.py line 42"); unfenced diffs and hunks dropped; Claude Code tool-call lines, tool output and `(ctrl+o to expand)` dropped |
| article | `source: article`, any `url` read, `/v2/renders` with `source_kind` web/pdf/epub | base, plus: figure captions, photo credits, "Advertisement" lines, image alt text and reference lists (in the second half of the text) dropped; each line is its own paragraph |
| literal | `prep: literal` (`myna_prep: literal` on `/v1/audio/speech`) | no cleanup: the text as written (pronunciations still apply, below) |

It is deterministic and idempotent, so History shows a past read "as heard"
by calling:

### `POST /v2/speakable`

Request `V2SpeakableReq`: `{"text": "…", "source": "claude_code", "prep": "auto", "source_kind": null}`
(`source`, `prep`, `source_kind` optional). Response `V2SpeakableResp`:
`{"ok": true, "text": "…", "changed": true, "preset": "claude_code"}`.
`changed` is false when only spacing or line breaks differ. Errors:
`400 empty` (blank text), `413 input_too_long` (over 2,000,000 characters),
`422` (a `prep` other than auto/literal).

### Pronunciations — `/v2/pronunciations` (`myna/pronunciations.py`)

After cleanup (and under `prep: literal` too, since a pronunciation is about
how a word sounds, not which text is read), every path runs the
pronunciation list: word or phrase → respelling ("kubectl" → "cube
control"). Case-insensitive, whole-word ("SQL" never touches "SQLite"),
longest entry first, one pass (a respelling is never matched again). It is
the user's entries plus a starter list of tech words Kokoro gets wrong
(`myna/pronunciation_lexicon.py`, each checked against Kokoro's own G2P);
a user entry for the same word wins. `/v2/speakable` applies it too, so
History's "As heard" shows the respellings, as the list stands now.

Stored in `~/.config/myna/pronunciations.json` by the daemon the app talks
to (`python -m myna`); any other instance (a dev worktree, tests) keeps its
list in memory. Every endpoint answers with the whole list:

```json
{"starter_enabled": true,
 "entries": [{"id": "p_1a2b3c4d", "word": "Anthropic", "say": "an throw pick", "enabled": true}],
 "starter": [{"id": "kubectl", "word": "kubectl", "say": "cube control", "heard": "kyoo-bect-l",
              "enabled": true, "overridden": false}]}
```

| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/v2/pronunciations` | — | the list |
| POST | `/v2/pronunciations` | `{"word", "say", "enabled"?}` | adds, or replaces the say of the user's entry for the same word |
| PATCH | `/v2/pronunciations/{id}` | `{"word"?, "say"?, "enabled"?}` | `404 not_found`, `409 duplicate_word` |
| DELETE | `/v2/pronunciations/{id}` | — | `404 not_found` |
| PATCH | `/v2/pronunciations/starter` | `{"enabled"}` | the whole starter list on/off |
| PATCH | `/v2/pronunciations/starter/{id}` | `{"enabled"}` | one starter entry; `404 not_found` |

Errors are `{"ok": false, "reason", "detail"}`: `invalid_word` (blank, no
letter or digit, over 80 characters), `invalid_say` (blank, over 200).

