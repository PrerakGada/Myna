"""Engine supervisor — the daemon owns the mlx-audio engine as a child
process so the entire voice stack is managed by a single brew service
(`myna-daemon`), instead of a separate `dev.myna.engine` LaunchAgent.

Lifecycle:
  • start(): evict any legacy `dev.myna.engine` LaunchAgent (migration from the
    two-service world), then run a background watchdog that ensures the engine
    is up — if nothing answers on the engine port we spawn
    `<venv>/bin/python -m mlx_audio.server` with the espeak/G2P env Kokoro needs.
  • The watchdog re-spawns the engine if our child dies while the daemon keeps
    running.
  • stop(): terminate our child, so stopping the daemon stops the engine.

If the engine venv isn't installed yet (setup hasn't run), spawning is a no-op
— the daemon still serves `/v2/health` with `engine_up=False`, the in-app Setup
flow installs the venv, and the watchdog then brings the engine up on its next
tick. Existing engines we didn't start (a dev-run engine, or an orphan from a
SIGKILLed daemon) are left alone: we only spawn when the port is dead.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import threading
import urllib.parse

from .engine import engine_up

logger = logging.getLogger(__name__)

_LEGACY_LAUNCH_AGENT = "dev.myna.engine"


class EngineSupervisor:
    def __init__(
        self,
        *,
        engine_url: str,
        venv_dir: str,
        log_path: str,
        poll_interval: float = 5.0,
    ):
        self._engine_url = engine_url
        self._venv_python = os.path.join(
            os.path.expanduser(venv_dir), "bin", "python"
        )
        self._log_path = os.path.expanduser(log_path)
        self._poll = poll_interval
        self._proc: subprocess.Popen | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

        parsed = urllib.parse.urlparse(engine_url)
        self._host = parsed.hostname or "127.0.0.1"
        self._port = parsed.port or 8765

    # ----- lifecycle -----

    def start(self) -> None:
        self._evict_legacy_launchagent()
        self._thread = threading.Thread(
            target=self._run, name="myna-engine-supervisor", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._terminate_child()
        if self._thread is not None:
            self._thread.join(timeout=3.0)

    # ----- watchdog -----

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._ensure_running()
            except Exception:
                logger.exception("engine supervisor tick failed")
            self._stop.wait(self._poll)

    def _ensure_running(self) -> None:
        # Something already serving (our child still warming, a dev-run engine,
        # or an orphan) — leave it be.
        if engine_up(self._engine_url):
            return
        # A child we spawned is still coming up — give it time, don't double.
        if self._proc is not None and self._proc.poll() is None:
            return
        self._spawn()

    def _spawn(self) -> None:
        if not os.path.exists(self._venv_python):
            logger.info(
                "engine venv missing (%s) — not spawning; run `myna setup`",
                self._venv_python,
            )
            return
        env = self._engine_env()
        try:
            os.makedirs(os.path.dirname(self._log_path), exist_ok=True)
            log = open(self._log_path, "a")
        except OSError:
            log = None
        logger.info(
            "spawning engine: %s -m mlx_audio.server --host %s --port %s",
            self._venv_python,
            self._host,
            self._port,
        )
        # start_new_session so the engine isn't collaterally signalled with the
        # daemon's process group; we own its teardown explicitly in stop().
        self._proc = subprocess.Popen(
            [
                self._venv_python,
                "-m",
                "mlx_audio.server",
                "--host",
                self._host,
                "--port",
                str(self._port),
            ],
            env=env,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )

    def _engine_env(self) -> dict:
        """Engine env incl. the bundled-espeak paths Kokoro's phonemizer needs.

        Mirrors what the old setup.sh LaunchAgent baked into the plist:
        PHONEMIZER_ESPEAK_LIBRARY + ESPEAK_DATA_PATH, resolved from the venv's
        espeakng_loader so we don't depend on a system espeak install.
        """
        env = dict(os.environ)
        try:
            out = subprocess.check_output(
                [
                    self._venv_python,
                    "-c",
                    "import espeakng_loader as e; "
                    "print(e.get_library_path()); print(e.get_data_path())",
                ],
                text=True,
                timeout=15,
            ).strip().splitlines()
            if len(out) >= 2 and out[0] and out[1]:
                env.setdefault("PHONEMIZER_ESPEAK_LIBRARY", out[0])
                env.setdefault("ESPEAK_DATA_PATH", out[1])
        except Exception:
            logger.info(
                "could not resolve espeak paths from venv; "
                "engine will fall back to a system espeak if present"
            )
        return env

    def _terminate_child(self) -> None:
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        try:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        except Exception:
            logger.exception("error terminating engine child")

    def _evict_legacy_launchagent(self) -> None:
        # Migration: older installs ran the engine via a `dev.myna.engine`
        # LaunchAgent. Unload it (bootout removes it from launchd, so its
        # KeepAlive won't restart it) so we don't end up with two engines
        # fighting over the port. Best-effort; a no-op on fresh installs.
        launchctl = shutil.which("launchctl") or "/bin/launchctl"
        target = f"gui/{os.getuid()}/{_LEGACY_LAUNCH_AGENT}"
        try:
            subprocess.run(
                [launchctl, "bootout", target],
                capture_output=True,
                timeout=10,
            )
        except Exception:
            pass
