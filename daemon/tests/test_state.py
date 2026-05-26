"""Unit tests for myna.state.StateMachine.

Covers every valid transition + a representative sample of invalid ones,
since_ms semantics, request_id lifecycle, and the force() escape hatch.
"""

import pytest

from myna.state import ALL_STATES, StateMachine


class FakeClock:
    """Manually advanced monotonic clock for deterministic since_ms tests."""

    def __init__(self, t: float = 1000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


# ---------- shape / construction ----------

def test_machine_starts_in_idle():
    m = StateMachine()
    assert m.state == "idle"
    assert m.request_id is None


def test_all_states_enumerated():
    # Sanity: the documented enum matches what's in the table.
    assert ALL_STATES == {"idle", "thinking", "speaking", "paused", "error"}


def test_snapshot_keys():
    m = StateMachine()
    snap = m.snapshot()
    assert set(snap) == {"state", "since_ms", "request_id"}


# ---------- valid transitions ----------

@pytest.mark.parametrize(
    "frm,to",
    [
        ("idle", "thinking"),
        ("idle", "error"),
        ("thinking", "speaking"),
        ("thinking", "idle"),
        ("thinking", "error"),
        ("speaking", "idle"),
        ("speaking", "paused"),
        ("speaking", "error"),
        ("paused", "speaking"),
        ("paused", "idle"),
        ("paused", "error"),
        ("error", "idle"),
        ("error", "thinking"),
    ],
)
def test_valid_transitions(frm, to):
    m = StateMachine()
    m.force(frm)
    assert m.transition_to(to) is True
    assert m.state == to


# ---------- invalid transitions ----------

@pytest.mark.parametrize(
    "frm,to",
    [
        ("idle", "speaking"),    # can't skip thinking
        ("idle", "paused"),
        ("thinking", "paused"),  # nothing to pause
        ("paused", "thinking"),  # spec'd as rejected
        ("error", "speaking"),
        ("error", "paused"),
        ("speaking", "thinking"),
    ],
)
def test_invalid_transitions_rejected(frm, to):
    m = StateMachine()
    m.force(frm)
    before = m.state
    assert m.transition_to(to) is False
    assert m.state == before


def test_unknown_state_rejected():
    m = StateMachine()
    assert m.transition_to("vibing") is False
    assert m.state == "idle"


# ---------- since_ms ----------

def test_since_ms_starts_at_zero_then_advances():
    clk = FakeClock()
    m = StateMachine(clock=clk)
    assert m.since_ms() == 0
    clk.advance(1.234)
    assert m.since_ms() == 1234


def test_since_ms_resets_on_transition():
    clk = FakeClock()
    m = StateMachine(clock=clk)
    clk.advance(5.0)
    assert m.since_ms() == 5000
    m.transition_to("thinking")
    assert m.since_ms() == 0
    clk.advance(0.5)
    assert m.since_ms() == 500


def test_same_state_transition_does_not_reset_since():
    clk = FakeClock()
    m = StateMachine(clock=clk)
    m.transition_to("thinking")
    clk.advance(2.0)
    assert m.since_ms() == 2000
    # Same-state "transition" is a no-op for the clock
    m.transition_to("thinking")
    assert m.since_ms() == 2000


# ---------- request_id ----------

def test_request_id_set_on_thinking():
    m = StateMachine()
    m.transition_to("thinking", request_id="r_1")
    assert m.request_id == "r_1"


def test_request_id_preserved_through_speaking():
    m = StateMachine()
    m.transition_to("thinking", request_id="r_2")
    m.transition_to("speaking")
    assert m.request_id == "r_2"


def test_request_id_cleared_on_idle():
    m = StateMachine()
    m.transition_to("thinking", request_id="r_3")
    m.transition_to("speaking")
    m.transition_to("idle")
    assert m.request_id is None


def test_request_id_preserved_through_error():
    m = StateMachine()
    m.transition_to("thinking", request_id="r_4")
    m.transition_to("error")
    assert m.request_id == "r_4"


def test_request_id_refreshable_in_same_state():
    m = StateMachine()
    m.transition_to("thinking", request_id="r_a")
    m.transition_to("thinking", request_id="r_b")
    assert m.request_id == "r_b"


# ---------- force ----------

def test_force_bypasses_validation():
    m = StateMachine()
    m.force("speaking", request_id="rec")
    assert m.state == "speaking"
    assert m.request_id == "rec"


def test_force_unknown_raises():
    m = StateMachine()
    with pytest.raises(ValueError):
        m.force("nope")


def test_force_to_idle_clears_request_id():
    m = StateMachine()
    m.transition_to("thinking", request_id="r_x")
    m.force("idle")
    assert m.request_id is None
