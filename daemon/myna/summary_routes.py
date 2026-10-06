"""Summary status, and summary failures as JSON the app can act on.

Registered from create_app with one call so app.py only grows a line or two.

- GET /v2/summarize/status: can the Ollama fallback run right now? The app's
  Summaries card shows it next to Apple Intelligence's own status, so the user
  knows which backend a summary will use before pressing the key.
- SummaryUnavailable (myna.summarize) raised anywhere in a request becomes
  503 {"ok": false, "reason", "detail"} instead of a bare 500, whether it came
  from /v2/synthesize, /v2/synthesize-summary or /v2/summarize.
"""

from __future__ import annotations

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from . import summarize as summarize_mod
from .v2_types import V2SummaryOllama, V2SummaryStatus


def register_summary_routes(app, cfg) -> None:
    # Tests swap in a fake probe the same way they swap app.state.summarize.
    app.state.ollama_status = summarize_mod.ollama_status

    @app.exception_handler(summarize_mod.SummaryUnavailable)
    async def _summary_unavailable(_request: Request, exc: summarize_mod.SummaryUnavailable):
        return JSONResponse(
            status_code=503,
            content={"ok": False, "reason": exc.reason, "detail": exc.detail},
        )

    @app.get("/v2/summarize/status", response_model=V2SummaryStatus)
    async def v2_summarize_status() -> V2SummaryStatus:
        probe = await run_in_threadpool(
            app.state.ollama_status, base_url=cfg["ollama_url"], model=cfg["summary_model"]
        )
        return V2SummaryStatus(
            ollama=V2SummaryOllama(**probe),
            styles=list(summarize_mod.STYLES),
            default_style=summarize_mod.DEFAULT_STYLE,
        )
