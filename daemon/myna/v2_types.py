"""Pydantic models for the v2 HTTP API.

Canonical schemas are documented in docs/native-app/API_CONTRACT.md § 5.
JSON shapes must match the test fixtures in docs/native-app/fixtures/.
"""

from typing import Literal, Optional

from pydantic import BaseModel


class V2SynthesizeReq(BaseModel):
    text: Optional[str] = None
    url: Optional[str] = None
    voice: Optional[str] = None
    speed: float = 1.0
    mode: Literal["full", "summary"] = "full"
    chunk_chars: Optional[int] = None
    session_id: Optional[str] = None
    # Voice wardrobe — if set, and the user hasn't passed an explicit
    # `voice`, the daemon looks up the configured voice for this bundle
    # id (e.g. "com.tinyspeck.slackmacgap") before falling back to the
    # global default.
    bundle_id: Optional[str] = None
    # Text prep (myna.speakable). `source` picks the cleanup preset
    # (claude_code, article, selection, clipboard, replay, …; unknown values
    # get the base pass). `prep: literal` reads the text exactly as written.
    source: Optional[str] = None
    prep: Literal["auto", "literal"] = "auto"
    # mode "summary" only: "tldr" | "key_points" | "action_items" |
    # "plain_english". Missing or unknown reads as "tldr" (myna.summarize).
    summary_style: Optional[str] = None


class V2SpeakableReq(BaseModel):
    """POST /v2/speakable: what a read of `text` would say, without saying it."""

    text: str
    source: Optional[str] = None
    prep: Literal["auto", "literal"] = "auto"
    # A document's kind (Studio: web, pdf, epub, markdown, …). web/pdf/epub
    # get the article preset.
    source_kind: Optional[str] = None


class V2SpeakableResp(BaseModel):
    ok: bool = True
    text: str
    # Whether the words or punctuation differ from the input (spacing and
    # line breaks alone don't count).
    changed: bool
    # base | claude_code | article | literal
    preset: str


class V2ExtractReq(BaseModel):
    url: str


class V2ExtractResp(BaseModel):
    ok: bool
    text: Optional[str] = None
    title: Optional[str] = None
    byline: Optional[str] = None
    reason: Optional[str] = None


class V2SummarizeReq(BaseModel):
    text: str
    summary_style: Optional[str] = None


class V2SummarizeResp(BaseModel):
    ok: bool
    summary: Optional[str] = None
    reason: Optional[str] = None


class V2SummaryOllama(BaseModel):
    # "ready" | "model_missing" | "not_running" | "not_installed"
    state: str
    model: str
    url: str


class V2SummaryStatus(BaseModel):
    """GET /v2/summarize/status — whether the Ollama fallback can run."""

    ok: bool = True
    ollama: V2SummaryOllama
    styles: list[str]
    default_style: str


class V2EngineInfo(BaseModel):
    url: str
    status: str
    model: str
    last_check_age_s: float
    # Catalog id + display name of the active engine (myna.engines).
    id: Optional[str] = None
    name: Optional[str] = None


class V2DaemonInfo(BaseModel):
    version: str
    uptime_s: float
    pid: int


class V2ConfigInfo(BaseModel):
    voice: str
    speed: float
    lang_code: str
    chunk_chars: int
    summary_model: str


class V2RegistryItem(BaseModel):
    id: str
    label: str
    age_s: int
    preview: str


class V2RegistryInfo(BaseModel):
    count: int
    items: list[V2RegistryItem]


class V2V1PlayerInfo(BaseModel):
    state: str
    now_playing: Optional[dict] = None


class V2Status(BaseModel):
    # v0.1 fields (still required by the existing Swift decoder + fixture)
    state: str
    engine: V2EngineInfo
    daemon: V2DaemonInfo
    config: V2ConfigInfo
    registry: V2RegistryInfo
    v1_player: V2V1PlayerInfo
    # v0.2 additive fields (Track A consumes these)
    ok: bool = True
    version: str = ""
    engine_up: bool = False
    since_ms: int = 0
    request_id: Optional[str] = None


class V2Voice(BaseModel):
    id: str
    label: str
    lang: str
    default: bool
    # builtin | clip | blend. Clips and blends are the user's own
    # (myna.voice_store); only the engines that can speak them list them.
    kind: Optional[str] = None
    # How pickers file it: "American English", "Built-in", "Your voices"…
    group: Optional[str] = None
    gender: Optional[str] = None
    # Kokoro's own quality grade (A … F) where the model card gives one.
    grade: Optional[str] = None
    detail: Optional[str] = None
    credit: Optional[str] = None


class V2VoicesEngine(BaseModel):
    """What the active engine can do with voices, for the Voices screen."""

    id: str
    name: str
    can_clone: bool
    can_blend: bool
    note: Optional[str] = None


class V2Voices(BaseModel):
    voices: list[V2Voice]
    # "down" only, and only when the engine is unreachable.
    engine: Optional[str] = None
    active_engine: Optional[V2VoicesEngine] = None


class V2BlendPart(BaseModel):
    voice: str
    weight: int = 1


class V2BlendReq(BaseModel):
    name: Optional[str] = None
    mix: list[V2BlendPart]


class V2VoiceRenameReq(BaseModel):
    name: str


class V2LibraryVoice(BaseModel):
    id: str
    name: str
    group: str
    gender: Optional[str] = None
    age: Optional[int] = None
    detail: str
    license: str
    credit: str
    size_kb: int
    # The user's voice id once added (voice_store clip), else absent.
    added_as: Optional[str] = None


class V2Library(BaseModel):
    voices: list[V2LibraryVoice]
    source: str


class V2Health(BaseModel):
    ok: bool
    version: str
    engine_up: bool


# ---- v2 registry (CC-hook toast) ----

class V2RegistryAnnounceReq(BaseModel):
    id: str
    source: str = "claude-code"
    project_id: str
    title: str
    # Full reply body. `title` is only the first-line preview; `text` is what
    # /play/{id} (and the Swift pill) actually speak so the whole output is
    # read, not just the opening sentence. Optional for back-compat with
    # callers (and persisted entries) that predate it — those fall back to
    # `title`.
    text: Optional[str] = None
    ttl_s: int = 600
    # Claude Code hands-free. "reply" (the Stop hook, the default) or
    # "attention" (the Notification hook: a session needs the user). Any
    # other value is stored as a reply. See v2_registry.py.
    kind: str = "reply"
    session_id: Optional[str] = None
    # attention only: Claude Code's notification_type (permission_prompt, …)
    notification_type: Optional[str] = None
    # Bundle id of the app the session runs in (from the hook's environment),
    # so the app can tell whether that window is in front.
    host_bundle_id: Optional[str] = None
    # Note: `audio_path` was intentionally dropped — it allowed an
    # unauthenticated arbitrary-file delete via /dismiss. Pydantic
    # silently ignores extra keys by default, so first-party callers
    # that still send it will not error.


class V2RegistryAnnounceResp(BaseModel):
    ok: bool
    announced_at_ms: int


class V2RegistryEntry(BaseModel):
    id: str
    source: str
    project_id: str
    title: str
    # Full reply body (see V2RegistryAnnounceReq.text). Optional so /list
    # stays valid for entries persisted before this field existed.
    text: Optional[str] = None
    announced_at_ms: int
    ttl_s: int
    played_at_ms: Optional[int] = None
    dismissed_at_ms: Optional[int] = None
    # Claude Code hands-free fields; defaulted so entries persisted before
    # them still validate.
    kind: str = "reply"
    session_id: Optional[str] = None
    notification_type: Optional[str] = None
    host_bundle_id: Optional[str] = None
    partly_heard: bool = False


class V2RegistryListResp(BaseModel):
    pending: list[V2RegistryEntry]
    played: list[V2RegistryEntry]


class V2RegistryPlayReq(BaseModel):
    # Optional override for what to speak instead of the stored body. The
    # app sends the reply's bold claims here when "Read only the bold
    # claims" is on; the extraction lives app-side next to the setting.
    # Omitted (or blank) → the stored `text`, then `title`, as before.
    text: Optional[str] = None


class V2RegistryActionResp(BaseModel):
    ok: bool
    reason: Optional[str] = None


class V2RegistryPartlyHeardReq(BaseModel):
    # The part of the reply the user hasn't heard yet.
    text: str


class V2RegistryPartlyHeardResp(BaseModel):
    ok: bool
    # Id of the fresh pending entry holding the rest.
    id: Optional[str] = None
    reason: Optional[str] = None


# ---- v2 voice wardrobe + model status ----

class V2VoiceWardrobeEntry(BaseModel):
    bundle_id: str
    voice_id: Optional[str] = None


class V2VoiceWardrobe(BaseModel):
    mappings: dict[str, str]


class V2ModelStatus(BaseModel):
    """Snapshot of the daemon's TTS-engine-related resource usage.

    Note: the daemon process itself does **not** hold the Kokoro model
    in RAM — the model lives in a separate engine process at
    ``engine_url``. ``model_loaded`` reflects whether that engine is
    currently reachable; ``daemon_rss_mb`` is the daemon's own
    resident-set size for completeness.
    """

    model_loaded: bool
    engine_url: str
    daemon_rss_mb: float
    daemon_pid: int
    # Physical footprint (Activity Monitor's "Memory") of the engine process,
    # where the model's weights actually live. None when it can't be read.
    engine_memory_mb: Optional[float] = None
    engine_pid: Optional[int] = None
    # True iff the daemon can meaningfully suspend the TTS model on
    # request. Because Myna talks to an out-of-process engine, this is
    # always false today; the field exists so the Swift UI can hide the
    # "Pause Myna" toggle if the daemon can't honour it.
    suspend_supported: bool


# ----- voice engines -----


class V2EngineStats(BaseModel):
    first_word_s: float
    stream_first_s: Optional[float] = None
    speed_x: float
    peak_memory_mb: float
    word_error_pct: float
    measured_on: str


class V2EngineVoice(BaseModel):
    id: str
    label: str


class V2Engine(BaseModel):
    id: str
    name: str
    maker: str
    tagline: str
    description: str
    repo: str
    params: str
    languages: list[str]
    license: str
    credit: Optional[str] = None
    badge: Optional[str] = None
    download_mb: int
    sample_rate: int
    native_speed: bool
    cloning: bool
    blending: bool = False
    voices: list[V2EngineVoice]
    default_voice: str
    stats: V2EngineStats
    active: bool
    # installed | downloading | failed | not_installed
    state: str
    progress: Optional[float] = None
    downloaded_mb: Optional[float] = None
    total_mb: Optional[float] = None
    disk_mb: Optional[float] = None
    error: Optional[str] = None


class V2Engines(BaseModel):
    active: str
    # Set while a switch is loading the new model into the engine.
    switching_to: Optional[str] = None
    engines: list[V2Engine]


class V2EngineActivateResp(BaseModel):
    ok: bool
    active: str
    voice: str
    load_s: float
