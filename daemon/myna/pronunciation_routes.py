"""/v2/pronunciations: the user's pronunciation list (myna.pronunciations),
and `app.state.speakable`, the one text-prep call every read, summary and
render goes through, so the list always applies.

Registered from create_app with one call, like the render routes.

  GET    /v2/pronunciations                   the list
  POST   /v2/pronunciations                   add (or replace the say of the same word)
  PATCH  /v2/pronunciations/starter           switch the whole starter list on/off
  PATCH  /v2/pronunciations/starter/{id}      switch one starter entry on/off
  PATCH  /v2/pronunciations/{id}              edit one of the user's entries
  DELETE /v2/pronunciations/{id}              remove one of the user's entries

Every answer is the whole list, so a client never has to merge.
"""

from __future__ import annotations

from typing import Optional

from fastapi.responses import JSONResponse
from pydantic import BaseModel

from . import pronunciations as pron
from . import speakable as speakable_mod


class PronunciationAdd(BaseModel):
    word: str
    say: str
    enabled: bool = True


class PronunciationEdit(BaseModel):
    word: Optional[str] = None
    say: Optional[str] = None
    enabled: Optional[bool] = None


class StarterSwitch(BaseModel):
    enabled: bool


def _error(status: int, reason: str, detail: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"ok": False, "reason": reason, "detail": detail})


def register_pronunciation_routes(app, cfg: dict, *, persist_config: bool) -> None:
    if not hasattr(app.state, "pronunciations"):
        app.state.pronunciations = None

    def store() -> pron.PronunciationStore:
        """The list, created on first use. Only the service the app talks to
        (`python -m myna` sets service_port) reads and writes the user's
        file; any other instance keeps its changes in memory."""
        current = app.state.pronunciations
        if current is None:
            primary = persist_config and getattr(app.state, "service_port", None) == cfg.get("daemon_port")
            current = pron.PronunciationStore(pron.default_path() if primary else None)
            app.state.pronunciations = current
        return current

    def speakable(text: str, **kw) -> str:
        return speakable_mod.speakable(text, substitutions=(store().stage(),), **kw)

    app.state.pronunciation_store = store
    app.state.speakable = speakable

    @app.get("/v2/pronunciations")
    def v2_pronunciations():
        return store().snapshot()

    @app.post("/v2/pronunciations")
    def v2_pronunciations_add(req: PronunciationAdd):
        try:
            store().add(req.word, req.say, req.enabled)
        except pron.PronunciationError as exc:
            return _error(400, exc.reason, exc.detail)
        return store().snapshot()

    # Registered before /{entry_id} so "starter" is never taken for an id.
    @app.patch("/v2/pronunciations/starter")
    def v2_pronunciations_starter(req: StarterSwitch):
        store().set_starter_enabled(req.enabled)
        return store().snapshot()

    @app.patch("/v2/pronunciations/starter/{entry_id}")
    def v2_pronunciations_starter_entry(entry_id: str, req: StarterSwitch):
        try:
            store().set_starter_entry(entry_id, req.enabled)
        except KeyError:
            return _error(404, "not_found", "No starter entry with that id.")
        return store().snapshot()

    @app.patch("/v2/pronunciations/{entry_id}")
    def v2_pronunciations_edit(entry_id: str, req: PronunciationEdit):
        try:
            store().update(entry_id, word=req.word, say=req.say, enabled=req.enabled)
        except KeyError:
            return _error(404, "not_found", "No pronunciation with that id.")
        except pron.PronunciationError as exc:
            status = 409 if exc.reason == "duplicate_word" else 400
            return _error(status, exc.reason, exc.detail)
        return store().snapshot()

    @app.delete("/v2/pronunciations/{entry_id}")
    def v2_pronunciations_delete(entry_id: str):
        if not store().delete(entry_id):
            return _error(404, "not_found", "No pronunciation with that id.")
        return store().snapshot()
