import signal
import time

from myna.player import Player


class FakeProc:
    def __init__(self, pid=111, polls_until_done=1):
        self.pid = pid
        self._polls = polls_until_done
        self.killed = False

    def poll(self):
        if self._polls <= 0:
            return 0
        self._polls -= 1
        return None

    def kill(self):
        self.killed = True
        self._polls = 0


def _wait_idle(player, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        if player.status()["state"] == "idle":
            return
        time.sleep(0.01)
    raise AssertionError("player did not return to idle")


def test_play_consumes_all_chunks():
    spawned = []

    def spawn(path):
        spawned.append(path)
        return FakeProc(polls_until_done=0)

    p = Player(spawn=spawn, sig=lambda pid, s: None)
    p.play(iter(["a.wav", "b.wav"]), meta={"source": "test"})
    _wait_idle(p)
    assert spawned == ["a.wav", "b.wav"]


def test_pause_resume_send_signals():
    sent = []
    p = Player(spawn=lambda path: FakeProc(), sig=lambda pid, s: sent.append((pid, s)))
    # Simulate active playback
    p._state = "playing"
    p._proc = FakeProc(pid=222)
    p.pause()
    assert p.status()["state"] == "paused"
    assert sent == [(222, signal.SIGSTOP)]
    p.resume()
    assert p.status()["state"] == "playing"
    assert sent == [(222, signal.SIGSTOP), (222, signal.SIGCONT)]


def test_stop_kills_current_proc():
    proc = FakeProc(pid=333)
    p = Player(spawn=lambda path: proc, sig=lambda pid, s: None)
    p._state = "playing"
    p._proc = proc
    p.stop()
    assert proc.killed is True
    assert p.status()["state"] == "idle"
