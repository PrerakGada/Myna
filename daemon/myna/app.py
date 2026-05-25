import pathlib
import uuid

from fastapi import FastAPI
from pydantic import BaseModel

from . import chunking, engine
from . import extract as extract_mod
from . import summarize as summarize_mod
from .config import load_config
from .player import Player
from .registry import Registry


class SpeakReq(BaseModel):
    text: str | None = None
    url: str | None = None
    mode: str = "full"
    voice: str | None = None
    speed: float | None = None
    source: str | None = None


class AnnounceReq(BaseModel):
    session_id: str
    label: str
    text: str


class SpeedReq(BaseModel):
    value: float


def create_app(config: dict | None = None) -> FastAPI:
    app = FastAPI(title="Myna")
    cfg = config or load_config()
    app.state.cfg = cfg
    app.state.speed = cfg["speed"]
    app.state.player = Player()
    app.state.registry = Registry()
    app.state.synthesize = engine.synthesize
    app.state.engine_up = engine.engine_up
    app.state.summarize = summarize_mod.summarize
    app.state.extract = extract_mod.extract_article

    tmpdir = pathlib.Path.home() / ".cache" / "myna" / "tmp"

    def _producer(text, voice, speed):
        tmpdir.mkdir(parents=True, exist_ok=True)
        for chunk in chunking.chunk_text(text, cfg["chunk_chars"]):
            wav = app.state.synthesize(
                chunk,
                voice=voice,
                speed=speed,
                base_url=cfg["engine_url"],
                model=cfg["model"],
                lang_code=cfg["lang_code"],
            )
            p = tmpdir / f"{uuid.uuid4().hex}.wav"
            p.write_bytes(wav)
            yield str(p)

    def _speak(req: SpeakReq):
        text = req.text
        if req.url:
            text = app.state.extract(req.url)
            if not text:
                return {"ok": False, "reason": "extract_failed"}
        text = (text or "").strip()
        if not text:
            return {"ok": False, "reason": "empty"}
        if req.mode == "summary":
            text = app.state.summarize(
                text,
                model=cfg["summary_model"],
                base_url=cfg["ollama_url"],
                think=cfg["summary_think"],
                timeout=cfg["summary_timeout"],
            )
        voice = req.voice or cfg["voice"]
        speed = req.speed or app.state.speed
        app.state.player.play(
            _producer(text, voice, speed),
            meta={"source": req.source or "speak", "preview": text[:60]},
        )
        return {"ok": True}

    @app.post("/speak")
    def speak(req: SpeakReq):
        return _speak(req)

    @app.post("/announce")
    def announce(req: AnnounceReq):
        rid = app.state.registry.add(req.label, req.text)
        return {"ok": True, "id": rid}

    @app.get("/registry")
    def registry():
        return {"items": app.state.registry.list_items()}

    @app.post("/play/{item_id}")
    def play_item(item_id: str, mode: str = "full"):
        item = app.state.registry.pop(item_id)
        if not item:
            return {"ok": False, "reason": "not_found"}
        return _speak(SpeakReq(text=item["text"], mode=mode, source=item["label"]))

    @app.post("/pause")
    def pause():
        app.state.player.pause()
        return {"ok": True}

    @app.post("/resume")
    def resume():
        app.state.player.resume()
        return {"ok": True}

    @app.post("/stop")
    def stop():
        app.state.player.stop()
        return {"ok": True}

    @app.post("/speed")
    def speed(req: SpeedReq):
        app.state.speed = max(0.5, min(2.0, req.value))
        return {"ok": True, "speed": app.state.speed}

    @app.get("/status")
    def status():
        st = app.state.player.status()
        return {
            "state": st["state"],
            "now_playing": st["now_playing"],
            "speed": app.state.speed,
            "registry_count": len(app.state.registry.list_items()),
            "engine": "up" if app.state.engine_up(cfg["engine_url"]) else "down",
        }

    return app
