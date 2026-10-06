# Render API — finished audio files out of Myna

Status: **contract**, 29 Sep 2026. Written before the implementation so the
daemon, the Swift client (`apps/macos/Sources/Network/RenderClient.swift`,
`RenderTypes.swift`) and the three Create panes (Playground, Studio, API)
build against one definition. If the implementation has to differ, change this
file and the Swift types in the same commit.

Implementation: `daemon/myna/render_routes.py` (routes), `render.py`
(voices, chunking, synthesis), `render_jobs.py` (queue, worker, library),
`encode.py` (formats), `api_access.py` (LAN access, key, request log).
Tests: `daemon/tests/test_render_*.py`.

Until now every synthesis path streamed into Myna's own player:
`/v2/synthesize` drives the menu-bar state machine, the karaoke ribbon and the
pill. Nothing produced a finished file. This adds one renderer in the daemon
and three ways in:

| Way in | Who uses it | Shape |
|---|---|---|
| `POST /v1/audio/speech` | any OpenAI-TTS client, scripts, Playground | synchronous, returns audio bytes |
| `/v2/renders` jobs | Studio, API users with long documents | async job, progress, file on disk |
| `POST /v2/transcode` | Playground "save as" | re-encode WAV already in hand |

**None of these touch the state machine, the karaoke ribbon, the pill, the
remembered voice, or History.** A render is not a read. Voice resolution goes
through `app.state.engine_kwargs(voice, remember=False)` so every engine's own
sampling settings and voices apply (that function is the single source of
truth; do not duplicate voice logic).

**Only the active engine renders.** Switching engines loads/unloads models in
the shared engine process and would pull the model out from under a live read,
so a render never switches. A request naming another engine gets
`409 engine_not_active`.

**Live reads win.** Render jobs yield between chunks while the state machine is
`thinking` or `speaking` (a `thinking` older than 45 s counts as stuck and is
ignored, as voice previews do) or an engine switch is loading a model, so
pressing the hotkey during a long Studio render still speaks promptly.
Synchronous `/v1/audio/speech` doesn't wait.

"Promptly" is at chunk granularity: a read can wait behind the one render
chunk already in the engine. Renders use chunks of at most 400 characters
(reads use 1500) to bound that. Measured on Chatterbox, the slowest engine:
a read's first audio took 0.17 s idle and 1.5 s during a long render; with
1500-character chunks it could have been ~12 s.

---

## 1. OpenAI-compatible speech

### `POST /v1/audio/speech`

Drop-in for `https://api.openai.com/v1/audio/speech`: point any OpenAI client
at `http://127.0.0.1:8766/v1` with any API key string.

Request (JSON):

| field | type | notes |
|---|---|---|
| `input` | string, required | ≤ 40,000 characters. Longer → `413 input_too_long`; use `/v2/renders`. |
| `model` | string | `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts`, `myna` → the active engine. An engine id (`kokoro`, `soprano`, …) or its Hugging Face repo must be the active one, else `409 engine_not_active`; a model Myna doesn't know is `400 engine_not_active`. Default: active engine. |
| `voice` | string | A voice id of the active engine (see `/v1/audio/voices`), **or** an OpenAI voice name (`alloy ash ballad coral echo fable onyx nova sage shimmer verse`), mapped onto the active engine's voices at call time (rules under `/v1/audio/voices`). Unknown → the engine's remembered voice, else its default. |
| `response_format` | string | `mp3` (OpenAI's default) `opus` `aac` `flac` `wav` `pcm`, plus Myna's `m4a`. `pcm` = raw 16-bit little-endian mono at the engine's sample rate (header `X-Myna-Sample-Rate`). Unknown → `400 invalid_format`; a format this Mac can't encode → `400 format_unavailable`. |
| `speed` | number | 0.25–4.0 accepted (outside → `400 invalid_speed`), clamped to 0.5–2.0. Only engines with native speed (Kokoro) honour it; the others render at 1.0. |
| `instructions` | string | accepted and ignored. |
| `myna_prep` | string | Myna's own, optional: `auto` (default) cleans the input with the base text-prep pass first (markdown syntax, fenced code, long inline code, bare URLs and citation marks out; see `docs/api-contracts-daemon.md` § 7); `literal` reads it as written (the pronunciation list, `/v2/pronunciations`, still applies). Anything else → `400 invalid_request` (`param: myna_prep`). Other unknown fields are ignored, so OpenAI clients never break. |

Input that is empty once cleaned is `400 empty_input`. The cleaned text is
split into paragraphs (blank lines), then sentences, into chunks of
at most 400 characters (or `chunk_chars` from config, if smaller); each chunk
is one engine call, and the audio is joined into one file. A failed chunk is
retried once after a second.

Response `200`: the audio bytes, `Content-Type` per format
(`audio/mpeg`, `audio/ogg`, `audio/aac`, `audio/flac`, `audio/wav`,
`audio/L16`, `audio/mp4`), plus headers:

```
X-Myna-Engine: kokoro
X-Myna-Voice: af_heart
X-Myna-Duration-S: 12.48
X-Myna-Sample-Rate: 24000
X-Myna-Chunks: 3
X-Myna-Render-Ms: 1830
```

Errors use **OpenAI's error shape** so OpenAI SDKs surface them properly:

```json
{"error": {"message": "…", "type": "invalid_request_error", "param": "input", "code": "input_too_long"}}
```

codes: `empty_input`, `input_too_long` (413), `engine_not_active` (409/400),
`invalid_format`, `format_unavailable`, `invalid_speed`, `invalid_request`
(the body didn't parse), `engine_down` (503), `engine_error` (502),
`encode_failed` (500), `unauthorized` (401), `forbidden` (403). `type` is
`invalid_request_error` for 4xx and `server_error` for 5xx.

### `GET /v1/models`

OpenAI list shape: `{"object":"list","data":[{"id":"kokoro","object":"model","created":1790701030,"owned_by":"myna","name":"Kokoro","active": true}, …]}`
— Kokoro, the active engine and any other installed engine, plus the aliases
`myna`, `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` (aliases carry
`"alias_of": "<active engine id>"`). Listing an engine doesn't make it
usable here: only the active one renders.

### `GET /v1/audio/voices`

`{"engine":"kokoro","voices":[{"id":"af_heart","label":"Heart (female)","lang":"en","default":true}, …],"openai_aliases":{"alloy":"af_alloy", …}}`

`voices` is what `/v2/voices` reports for the active engine (the catalog's
list when the engine is down), plus any voice file in the model's own
`voices/` folder that the engine accepts. For Kokoro that adds its whole set
(`af_alloy`, `am_onyx`, `bm_fable`, …).

`openai_aliases` is worked out from that list on every call, never from a
per-engine table, so it follows engines as they gain voices:

1. Same name: `alloy` → `af_alloy`, `onyx` → `am_onyx`, `fable` → `bm_fable`.
2. Otherwise a voice of the same gender as OpenAI's (known from a Kokoro id or
   a "(female)"/"(male)" label), English voices first, spread so different
   OpenAI names land on different voices where the engine has enough.
3. Otherwise spread over the engine's voices in order, with `alloy` taking the
   engine's default. A one-voice engine (Chatterbox, Soprano) maps every name
   to that voice.

---

## 2. Render jobs

For anything long: articles, documents, books. One worker, FIFO queue,
persisted so the library survives a daemon restart. Files live in
`~/Library/Application Support/Myna/renders/<id>.<ext>`, index in
`~/Library/Application Support/Myna/renders/index.json`. A queued job's text
waits in `renders/sources/<id>.json` and is deleted once it has rendered, so
queued jobs carry on after a restart. A job that was `rendering` when the
daemon died comes back as `failed` with reason `interrupted`; its partial
audio is discarded.

Where the library lives: `renders_dir` in config wins. A daemon running on a
port other than the configured `daemon_port` (a dev worktree, a test
instance) uses `~/Library/Application Support/Myna/renders-<port>` so it
can't rewrite the real library's index. An app built without persisting
config (every test) uses a temp folder.

### `POST /v2/renders` → `201` RenderJob

```json
{
  "title": "Chapter 3 — The Long Walk",
  "text": "…",                  // exactly one of text / url / sections
  "url": null,
  "sections": [ {"title": "Chapter 1", "text": "…"} ],
  "voice": "af_heart",          // optional; OpenAI names accepted as above
  "speed": 1.0,
  "format": "m4a",              // m4a (default) | mp3 | wav | aac | flac | opus
  "source": "studio",           // studio | api | playground | cli | claude_code | article; default "api"
  "section_pause_ms": 1200,     // silence between sections, 0–10000, default 1200
  "prep": "auto",               // auto (default) | literal — text prep, below
  "source_kind": "pdf"          // optional: the document's kind (Studio's web, pdf, epub, markdown, …)
}
```

**Text prep.** Each section's text is cleaned when the job is created, so the
stored text, `chars`, `words`, `preview` and the chunks are what is spoken.
The preset follows `source` and `source_kind`: `claude_code` gets the Claude
Code rules; `source: "article"`, a `url` job, or `source_kind` `web`, `pdf`
or `epub` get the article rules (captions, ads, reference lists out);
anything else gets the base pass. `prep: "literal"` renders the text as
written. The pronunciation list (`/v2/pronunciations`) applies either way. Section titles are display-only and aren't changed. A job whose text
is empty once cleaned is `400 empty`. An unknown `prep` is `422`.

`sections` exists for documents with structure (EPUB chapters, Markdown
headings): each section's start time comes back in `chapters`, and `m4a`
output carries real chapter markers when ffmpeg is present (a stream-copy
remux; the audio isn't re-encoded). Checked with ffprobe and AVFoundation's
`chapterMetadataGroups`. Without ffmpeg the job still reports `chapters`; the
file just doesn't carry them. Sections with blank text are dropped; an empty
section title becomes "Section N".

`url` is fetched and reduced to its article text when the job is created
(the same extractor as `/v2/extract`), so a bad address fails the request,
not the job. `title` defaults to the article's title, else the first
section's title, else the first line of the text.

Errors: `400 one_input_required` (not exactly one of text/url/sections),
`400 empty` (also when nothing is left once cleaned), `400 invalid_url`, `400 extract_failed`, `400 invalid_format`,
`400 format_unavailable`, `400 invalid_speed`, `413 input_too_long`
(over 2,000,000 characters).

### RenderJob

```json
{
  "id": "r_7f3a9c21",
  "title": "Chapter 3 — The Long Walk",
  "status": "rendering",        // queued | rendering | encoding | done | failed | cancelled
  "source": "studio",
  "created_at": 1790701030.2,   // unix seconds
  "started_at": 1790701031.0,
  "finished_at": null,
  "engine": "kokoro",
  "voice": "af_heart",
  "speed": 1.0,
  "format": "m4a",
  "chars": 48211,
  "words": 8420,
  "chunks_total": 41,
  "chunks_done": 17,
  "progress": 0.41,             // 0…1, chunk-weighted by characters
  "audio_s": 1204.6,            // audio produced so far (final duration when done)
  "eta_s": 95.0,                // null until two chunks have finished
  "file_path": null,            // absolute path once done
  "bytes": null,
  "chapters": [ {"title": "Chapter 1", "start_s": 0.0} ],
  "error": null,                // {"reason": "engine_error", "detail": "…"}
  "preview": "It was late when…" // first ~160 chars of the text
}
```

* `speed` is the speed actually applied: engines without native speed
  report `1.0` whatever was asked.
* `voice` is the engine voice the job renders with (an OpenAI name is
  resolved when the job is created).
* `chapters` is `null` for a text or url job. For a sections job it grows as
  rendering reaches each section.
* `eta_s` is estimated from the synthesis time so far (time spent waiting
  for live reads doesn't count); `0.0` once done, `null` when not rendering.
* `error.reason`: `interrupted` (the daemon stopped mid-render),
  `engine_changed` (the user switched engines after queueing: start it
  again), `engine_down` / `engine_error` (after retrying the chunk 3 times,
  2, 5 and 10 s apart), `encode_failed`.

### Other job endpoints

| endpoint | returns |
|---|---|
| `GET /v2/renders` | `{"renders": [RenderJob…]}` newest first |
| `GET /v2/renders/{id}` | RenderJob, `404` if unknown |
| `GET /v2/renders/{id}/audio` | the file, `Content-Disposition: attachment` named after the title (`409 not_ready` before `done`, `404 file_missing` if the file was deleted by hand) |
| `POST /v2/renders/{id}/cancel` | RenderJob (`cancelled`; partial audio discarded). Takes effect between chunks. A finished job comes back unchanged. |
| `DELETE /v2/renders/{id}` | `{"ok": true}` — removes the job and its file (cancels it first if it's running) |

Unknown or malformed ids are `404 not_found`.

Errors on `/v2/*` keep the existing daemon shape: `{"ok": false, "reason": "…", "detail": "…"}`.

---

## 3. Formats and transcoding

### `GET /v2/formats`

What this Mac can encode right now, so the UI can grey out the rest:

```json
{"formats": [
  {"id": "wav",  "label": "WAV",              "available": true,  "ext": "wav",  "mime": "audio/wav"},
  {"id": "m4a",  "label": "M4A (AAC)",        "available": true,  "ext": "m4a",  "mime": "audio/mp4"},
  {"id": "mp3",  "label": "MP3",              "available": false, "ext": "mp3",  "mime": "audio/mpeg",
   "reason": "needs ffmpeg or lame"},
  {"id": "aac",  "label": "AAC (ADTS)",       "available": true,  "ext": "aac",  "mime": "audio/aac"},
  {"id": "flac", "label": "FLAC",             "available": true,  "ext": "flac", "mime": "audio/flac"},
  {"id": "opus", "label": "Ogg Opus",         "available": false, "ext": "opus", "mime": "audio/ogg",
   "reason": "needs ffmpeg with libopus"},
  {"id": "pcm",  "label": "PCM (raw 16-bit)", "available": true,  "ext": "pcm",  "mime": "audio/L16"}
]}
```

Always all seven, in this order. WAV and PCM are always available (stdlib).
AAC/M4A and FLAC use the system `/usr/bin/afconvert` (AAC at 64 kbit/s).
MP3 needs `ffmpeg` built with libmp3lame, or `lame` (64 kbit/s); Ogg Opus
needs `ffmpeg` built with libopus (32 kbit/s). Tools are looked for on PATH
and in `/opt/homebrew/bin` and `/usr/local/bin` (launchd gives the
standalone daemon a PATH without Homebrew). That's present on a Homebrew
developer's Mac, absent on a DMG user's. The probe is re-run at most once a
minute, so installing ffmpeg shows up without a restart.

### `POST /v2/transcode?format=m4a`

Body: `audio/wav` bytes. Returns the encoded bytes with the format's
`Content-Type`. `format` defaults to `m4a` and may be any id from
`/v2/formats`. Errors: `400 invalid_audio` (body isn't a WAV),
`400 invalid_format`, `400 format_unavailable` (this Mac can't),
`500 encode_failed`. Used by the Playground so "Save as MP3" doesn't
re-synthesize — sampled engines would produce a different take.

---

## 4. API access settings

The daemon binds `127.0.0.1` only. The API pane can opt into the local
network: config `api_lan: true` makes `python -m myna` bind `0.0.0.0`.

### `GET /v2/api/settings`

```json
{
  "base_url": "http://127.0.0.1:8766/v1",
  "lan_enabled": false,
  "lan_urls": ["http://192.168.1.20:8766/v1"],   // what other devices would use
  "api_key": "myna-…",          // returned only to loopback callers
  "requires_key_on_lan": true,
  "restart_pending": false
}
```

* `base_url` and `lan_urls` use the port the request came in on.
* `lan_urls`: this Mac's non-loopback, non-link-local IPv4 addresses (Wi-Fi,
  Ethernet, Tailscale, …) and its Bonjour name (`<LocalHostName>.local`),
  re-read at most every 30 s. They're listed whether or not LAN is on.
* `api_key` is `myna-` plus 32 url-safe characters from `secrets`, created
  on the first read and kept in config.json as `api_key` (beside `api_lan`).
  It is stored in plain text, like the rest of config.json.
* `restart_pending` is true while the setting and what the daemon is actually
  bound to differ.

### `POST /v2/api/settings`

`{"lan_enabled": true}` and/or `{"regenerate_key": true}` → the settings
object. Changing `lan_enabled` rebinds (the daemon restarts itself; the
response says `restart_pending: true`). A regenerated key works at once and
the old one stops working at once; no restart.

**Rebinding.** Every install mode runs `<python> -m myna` under launchd with
KeepAlive (Homebrew's `myna-daemon` wrapper, the standalone
`dev.myna.daemon` agent's "Myna Voice" python, this Mac's
`dev.myna.daemon.src`). About 0.3 s after answering, the daemon stops
serving (in-flight responses finish, the engine child and render worker
stop), then `os.execv`s itself with the same interpreter and `sys.orig_argv`:
same PID, so launchd sees nothing, and it binds from the new config. If exec
fails it exits 75 and KeepAlive relaunches it. The engine reloads its model
on the next read. A render that was mid-job comes back `interrupted`; queued
ones carry on. Turning LAN **off** refuses other devices immediately, before
the rebind. A daemon started with `uvicorn --factory` (`just daemon-watch`, a
test instance) can't rebind itself: the change is held in memory and
`restart_pending` stays true until it's restarted by hand.

**Persistence.** Settings are written to config.json only by the daemon the
app talks to (the configured `daemon_port`, persistence on). A second daemon
on another port keeps changes in memory, so it can never rebind the user's
real daemon on its next start.

Rules, enforced by middleware:

* Loopback callers never need a key. They must still send a loopback `Host`
  (`127.0.0.1` or `localhost`), else `400 Invalid host header`: the
  DNS-rebinding defence, unchanged.
* Non-loopback callers (LAN on) must send `Authorization: Bearer <api_key>`
  (compared in constant time), and may reach **only `/v1/*`** — never
  `/v2/*`, `/speak`, `/stop`, `/docs` or anything that controls this Mac.
  Everything else is `403 {"ok": false, "reason": "forbidden"}`. A missing or
  wrong key on `/v1/*` is `401` in OpenAI's shape (`code: unauthorized`,
  `WWW-Authenticate: Bearer`). Their `Host` isn't checked; the key is the
  guard.
* With LAN off, every non-loopback caller gets `403`, key or not.
* A request from this Mac to its own LAN address arrives from that address,
  so it is treated as a LAN caller. That's deliberate.

### `GET /v2/api/log?limit=100`

The last requests to `/v1/*` and `/v2/renders*`, newest first, in memory
only (a ring buffer of 200; `limit` is capped at 200). Rejected requests are
logged too, which is how the API pane shows a device trying the wrong key.
Studio's status polls (`GET /v2/renders` and `GET /v2/renders/{id}`) are
left out, or they would push everything else out of the buffer; audio
downloads are kept. `client` is the caller's IP (`testclient` in tests).

```json
{"requests": [{"at": 1790701030.2, "method": "POST", "path": "/v1/audio/speech",
  "client": "127.0.0.1", "user_agent": "OpenAI/Python 1.40.0", "status": 200,
  "ms": 1830, "chars": 412, "format": "mp3", "voice": "af_heart", "audio_s": 24.1}]}
```

Never log the input text itself — only its length.
