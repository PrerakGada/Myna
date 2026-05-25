import os
import signal
import subprocess
import threading
from typing import Callable, Iterator, Optional


class Player:
    """Plays a sequence of WAV files with pause/resume/stop on a single track."""

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

    def play(self, producer: Iterator[str], meta: dict) -> None:
        self.stop()
        self._stop = threading.Event()
        with self._lock:
            self._meta = meta
            self._state = "playing"
        self._thread = threading.Thread(
            target=self._run, args=(producer,), daemon=True
        )
        self._thread.start()

    def _run(self, producer: Iterator[str]) -> None:
        try:
            for path in producer:
                if self._stop.is_set():
                    break
                self._play_file(path)
        finally:
            with self._lock:
                self._proc = None
                self._state = "idle"
                self._meta = None

    def _play_file(self, path: str) -> None:
        with self._lock:
            self._proc = self._spawn(path)
            proc = self._proc
        while proc.poll() is None:
            if self._stop.is_set():
                proc.kill()
                return
            self._stop.wait(0.05)

    def pause(self) -> None:
        with self._lock:
            if self._state == "playing" and self._proc is not None:
                self._sig(self._proc.pid, signal.SIGSTOP)
                self._state = "paused"

    def resume(self) -> None:
        with self._lock:
            if self._state == "paused" and self._proc is not None:
                self._sig(self._proc.pid, signal.SIGCONT)
                self._state = "playing"

    def stop(self) -> None:
        self._stop.set()
        with self._lock:
            if self._proc is not None:
                try:
                    self._proc.kill()
                except Exception:
                    pass
            self._state = "idle"
            self._meta = None
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def status(self) -> dict:
        with self._lock:
            return {"state": self._state, "now_playing": self._meta}
