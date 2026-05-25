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
    state: str
    engine: V2EngineInfo
    daemon: V2DaemonInfo
    config: V2ConfigInfo
    registry: V2RegistryInfo
    v1_player: V2V1PlayerInfo


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
