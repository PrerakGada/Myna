"""Daemon state machine — single source of truth for `/v2/status.state`.

States (v0.2):
    idle      — daemon is up, engine ready, nothing playing
    thinking  — request received, engine warming or summary in-flight, no audio yet
    speaking  — audio is playing (first chunk hit the player)
    paused    — speaking interrupted by user
    error     — engine failure / stream truncation / explicit error
                (cleared on next successful request or explicit transition)

Valid transitions:
    idle      -> thinking, error
    thinking  -> speaking, idle, error
    speaking  -> idle, paused, error
    paused    -> speaking, idle, error
    error     -> idle, thinking

Invalid transitions are rejected (return False, logged at WARNING).

This module is intentionally synchronous + dependency-free: the FastAPI app
holds one instance per daemon as `app.state.machine`. Reads (`/v2/status`)
and writes (synth pipeline, hotkey handlers) happen from the same event
loop so no locking is needed.
"""

from __future__ import annotations

import logging
import time
from typing import Optional


logger = logging.getLogger(__name__)


_VALID = {
    "idle":     {"thinking", "error"},
    "thinking": {"speaking", "idle", "error"},
    "speaking": {"idle", "paused", "error"},
    "paused":   {"speaking", "idle", "error"},
    "error":    {"idle", "thinking"},
}

ALL_STATES = frozenset(_VALID.keys())


class StateMachine:
    """Single-instance state tracker.

    Time is parametrized via `clock` so tests can pin "now".
    """

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._state: str = "idle"
        self._entered_at: float = self._clock()
        self._request_id: Optional[str] = None

    @property
    def state(self) -> str:
        return self._state

    @property
    def request_id(self) -> Optional[str]:
        return self._request_id

    def since_ms(self) -> int:
        """Wall-clock delta (ms) since the current state was entered."""
        delta = max(0.0, self._clock() - self._entered_at)
        return int(delta * 1000)

    def snapshot(self) -> dict:
        """JSON-serialisable view, intended for `/v2/status`."""
        return {
            "state": self._state,
            "since_ms": self.since_ms(),
            "request_id": self._request_id,
        }

    def transition_to(
        self,
        new_state: str,
        request_id: Optional[str] = None,
    ) -> bool:
        """Attempt a transition. Returns True if accepted, False if rejected.

        - Unknown states are rejected.
        - Invalid transitions per the table above are rejected and logged.
        - Same-state "transitions" are accepted as no-ops (request_id may be
          refreshed; `since_ms` is NOT reset — only a real edge resets it).
        """
        if new_state not in ALL_STATES:
            logger.warning("rejected unknown state %r", new_state)
            return False

        if new_state == self._state:
            # Idempotent: keep the original entered_at; allow request_id refresh
            # only when transitioning from one in-flight request to another in
            # the same state would have been a real edge. For simplicity we
            # take the new request_id if provided.
            if request_id is not None:
                self._request_id = request_id
            return True

        if new_state not in _VALID[self._state]:
            logger.warning(
                "rejected invalid transition: %s -> %s",
                self._state,
                new_state,
            )
            return False

        self._state = new_state
        self._entered_at = self._clock()
        # Lifecycle of request_id: set on enter to thinking/speaking; cleared
        # on return to idle; preserved through paused/error (so the UI can
        # still display "the request that errored").
        if new_state == "idle":
            self._request_id = None
        elif request_id is not None:
            self._request_id = request_id
        # else: caller didn't pass one; keep whatever we already had
        return True

    def force(self, new_state: str, request_id: Optional[str] = None) -> None:
        """Escape hatch: unconditional set (used for tests / recovery paths).

        Not part of the normal API. Logs at INFO since it bypasses the table.
        """
        if new_state not in ALL_STATES:
            raise ValueError(f"unknown state {new_state!r}")
        logger.info("force state %s -> %s", self._state, new_state)
        self._state = new_state
        self._entered_at = self._clock()
        self._request_id = request_id if new_state != "idle" else None
