import os
import signal
import subprocess
import threading
from typing import Callable, Iterator, Optional


class Player:
    """Plays a sequence of WAV files with pause/resume/stop on a single track.

    A `listener` passed to `play` hears what the track does: `started()` as
    each file starts, `paused()`, `resumed()`, and `ended(reason)` once
    ("finished", "stopped" or "error"). myna.reading uses it to know which
    word is being spoken.
    """

    def __init__(
        self,
        spawn: Optional[Callable[[str], "subprocess.Popen"]] = None,
        sig: Callable[[int, int], None] = os.kill,
    ):
        self._spawn = spawn or (lambda path: subprocess.Popen(["afplay", path]))
        self._sig = sig
        self._lock = threading.RLock()
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._proc = None
        self._state = "idle"
        self._meta = None
        self._listener = None
        # Bumped by every play(). A run only touches the player's state while
        # it is still the newest; an older run can outlive stop()'s join when
        # its producer is in the middle of synthesizing.
        self._generation = 0

    def play(self, producer: Iterator[str], meta: dict, listener=None) -> None:
        self.stop()
        stop = threading.Event()
        with self._lock:
            self._generation += 1
            generation = self._generation
            self._stop = stop
            self._meta = meta
            self._state = "playing"
            self._listener = listener
        self._thread = threading.Thread(
            target=self._run, args=(producer, stop, generation, listener), daemon=True
        )
        self._thread.start()

    def _run(self, producer: Iterator[str], stop: threading.Event, generation: int, listener) -> None:
        # The run keeps its own stop event: play() swaps in a fresh one for
        # the next run, and an older run reading self._stop would see that
        # one unset and play on over the new read.
        reason = "finished"
        try:
            for path in producer:
                if stop.is_set():
                    break
                if not self._play_file(path, stop, generation, listener):
                    break
        except Exception:
            reason = "error"
            raise
        finally:
            if stop.is_set():
                reason = "stopped"
            with self._lock:
                if self._generation == generation:
                    self._proc = None
                    self._state = "idle"
                    self._meta = None
                    self._listener = None
            if listener is not None:
                listener.ended(reason)

    def _play_file(self, path: str, stop: threading.Event, generation: int, listener) -> bool:
        with self._lock:
            if stop.is_set() or self._generation != generation:
                return False
            self._proc = self._spawn(path)
            proc = self._proc
        if listener is not None:
            listener.started()
        while proc.poll() is None:
            if stop.is_set():
                proc.kill()
                return False
            stop.wait(0.05)
        return True

    def pause(self) -> None:
        with self._lock:
            if self._state == "playing" and self._proc is not None:
                self._sig(self._proc.pid, signal.SIGSTOP)
                self._state = "paused"
                if self._listener is not None:
                    self._listener.paused()

    def resume(self) -> None:
        with self._lock:
            if self._state == "paused" and self._proc is not None:
                self._sig(self._proc.pid, signal.SIGCONT)
                self._state = "playing"
                if self._listener is not None:
                    self._listener.resumed()

    def stop(self) -> None:
        self._stop.set()
        with self._lock:
            if self._proc is not None:
                try:
                    self._proc.kill()
                except Exception:
                    pass
            listener = self._listener
            self._state = "idle"
            self._meta = None
            self._listener = None
        # Say so now: the run's own ended() can be a whole synthesize away.
        if listener is not None:
            listener.ended("stopped")
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def status(self) -> dict:
        with self._lock:
            return {"state": self._state, "now_playing": self._meta}
