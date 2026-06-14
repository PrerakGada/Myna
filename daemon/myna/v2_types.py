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


class V2SummarizeResp(BaseModel):
    ok: bool
    summary: Optional[str] = None
    reason: Optional[str] = None


class V2EngineInfo(BaseModel):
    url: str
    status: str
    model: str
    last_check_age_s: float


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


class V2Voices(BaseModel):
    voices: list[V2Voice]
    engine: Optional[str] = None


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


class V2RegistryListResp(BaseModel):
    pending: list[V2RegistryEntry]
    played: list[V2RegistryEntry]


class V2RegistryActionResp(BaseModel):
    ok: bool
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
    # True iff the daemon can meaningfully suspend the TTS model on
    # request. Because Myna talks to an out-of-process engine, this is
    # always false today; the field exists so the Swift UI can hide the
    # "Pause Myna" toggle if the daemon can't honour it.
    suspend_supported: bool
