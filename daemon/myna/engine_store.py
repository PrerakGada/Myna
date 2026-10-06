"""Download, check and remove engine weights in the Hugging Face cache.

The daemon's own environment has no huggingface_hub, and doesn't need one:
downloads run as a child process of the ENGINE venv's interpreter (the one
mlx-audio lives in), so the files land exactly where mlx-audio will look for
them. Progress is read from outside by summing the bytes that have reached
the cache against the total the Hub API reports — no pipes to parse.

`HF_HUB_DISABLE_XET=1` is set for every download: in the Phase 0 bake-off
the Xet transfer path stalled twice mid-file (Qwen3's weights, Chatterbox's
tokenizer) and never recovered, while the plain LFS path finished both.
"""

from __future__ import annotations

import fnmatch
import json
import logging
import os
import pathlib
import shutil
import subprocess
import threading
import time
from typing import Optional

import httpx

from .engines import CATALOG, DEFAULT_ENGINE_ID, Download, EngineSpec

logger = logging.getLogger(__name__)

_WEIGHT_SUFFIXES = (".safetensors", ".pth", ".npz", ".bin")

_DOWNLOAD_SCRIPT = """
import json, sys
from huggingface_hub import snapshot_download
for d in json.loads(sys.argv[1]):
    snapshot_download(
        repo_id=d["repo"],
        revision=d.get("revision"),
        allow_patterns=d.get("allow_patterns"),
    )
"""


def hf_hub_dir() -> pathlib.Path:
    """The hub cache, honouring the same env vars huggingface_hub does."""
    if os.environ.get("HF_HUB_CACHE"):
        return pathlib.Path(os.environ["HF_HUB_CACHE"]).expanduser()
    home = os.environ.get("HF_HOME") or "~/.cache/huggingface"
    return pathlib.Path(home).expanduser() / "hub"


def repo_dir(repo: str, hub: Optional[pathlib.Path] = None) -> pathlib.Path:
    return (hub or hf_hub_dir()) / ("models--" + repo.replace("/", "--"))


def _blob_files(repo_root: pathlib.Path) -> dict[pathlib.Path, int]:
    """The real files behind a repo's blobs, keyed by resolved path.

    Newer huggingface_hub keeps content in a hub-wide store (hub/blobs/xx/…)
    and leaves a SYMLINK in each repo's blobs/ dir. Following the links is
    the only way to see a repo's true size, and to free it on removal.
    In-progress `.incomplete` files are included so progress moves.
    """
    out: dict[pathlib.Path, int] = {}
    blobs = repo_root / "blobs"
    if not blobs.exists():
        return out
    for entry in blobs.rglob("*"):
        try:
            if entry.is_dir() and not entry.is_symlink():
                continue
            target = entry.resolve()
            if target.is_file():
                out[target] = target.stat().st_size
        except OSError:
            continue
    return out


def _dir_bytes(repo_root: pathlib.Path) -> int:
    return sum(_blob_files(repo_root).values())


def _snapshot_complete(d: Download, hub: pathlib.Path) -> bool:
    """True when some snapshot of `d` holds all its files.

    huggingface_hub only links a file into snapshots/ once its blob is
    complete, and `is_file()` follows the link, so a dangling or missing
    link means "not downloaded". Leftover `.incomplete` blobs are ignored on
    purpose: a stalled attempt can leave one behind even after a later
    download finished the same file.
    """
    root = repo_dir(d.repo, hub)
    snaps = root / "snapshots"
    if not snaps.exists():
        return False
    candidates = [snaps / d.revision] if d.revision else list(snaps.iterdir())
    for snap in candidates:
        if not snap.is_dir():
            continue
        files = [p for p in snap.rglob("*") if p.is_file()]
        if d.allow_patterns:
            rel = {str(p.relative_to(snap)) for p in files}
            if all(any(fnmatch.fnmatch(r, pat) for r in rel) for pat in d.allow_patterns):
                return True
        elif any(p.name.endswith(_WEIGHT_SUFFIXES) for p in files):
            return True
    return False


class EngineStore:
    """Tracks which engines are on disk and runs at most one download each."""

    def __init__(
        self,
        *,
        venv_dir: str,
        hub_dir: Optional[pathlib.Path] = None,
        catalog: tuple[EngineSpec, ...] = CATALOG,
    ):
        self._python = os.path.join(os.path.expanduser(venv_dir), "bin", "python")
        self._hub = hub_dir
        self._catalog = {s.id: s for s in catalog}
        self._lock = threading.Lock()
        # engine_id -> {"started_at", "total_bytes", "base_bytes", "error", "proc"}
        self._jobs: dict[str, dict] = {}

    @property
    def hub(self) -> pathlib.Path:
        return self._hub or hf_hub_dir()

    # ----- state -----

    def is_installed(self, spec: EngineSpec) -> bool:
        if self.is_downloading(spec.id):
            return False
        return all(_snapshot_complete(d, self.hub) for d in spec.downloads)

    def is_downloading(self, engine_id: str) -> bool:
        with self._lock:
            job = self._jobs.get(engine_id)
            return bool(job and job.get("proc") is not None and job["proc"].poll() is None)

    def disk_mb(self, spec: EngineSpec) -> float:
        return sum(_dir_bytes(repo_dir(d.repo, self.hub)) for d in spec.downloads) / 1e6

    def status(self, spec: EngineSpec) -> dict:
        """`state` is one of installed / downloading / failed / not_installed."""
        with self._lock:
            job = dict(self._jobs.get(spec.id) or {})
        proc = job.get("proc")
        if proc is not None and proc.poll() is None:
            total = job.get("total_bytes") or spec.download_mb * 1e6
            done = max(0, self._bytes_on_disk(spec) - job.get("base_bytes", 0))
            return {
                "state": "downloading",
                "progress": min(0.99, done / total) if total else None,
                "downloaded_mb": round(done / 1e6, 1),
                "total_mb": round(total / 1e6, 1),
            }
        if self.is_installed(spec):
            return {"state": "installed", "disk_mb": round(self.disk_mb(spec), 1)}
        if job.get("error"):
            return {"state": "failed", "error": job["error"]}
        return {"state": "not_installed"}

    def _bytes_on_disk(self, spec: EngineSpec) -> int:
        return sum(_dir_bytes(repo_dir(d.repo, self.hub)) for d in spec.downloads)

    # ----- download -----

    def install(self, engine_id: str) -> dict:
        spec = self._catalog[engine_id]
        if not os.path.exists(self._python):
            raise RuntimeError("The voice engine isn't installed yet. Finish Myna's setup first.")
        with self._lock:
            job = self._jobs.get(engine_id)
            running = bool(job and job.get("proc") is not None and job["proc"].poll() is None)
            if not running:
                self._jobs[engine_id] = {"started_at": time.time()}
        if running:
            return self.status(spec)
        threading.Thread(
            target=self._run_download, args=(spec,), name=f"myna-download-{engine_id}", daemon=True
        ).start()
        # Give the thread a beat to register its child so the first poll
        # already reads "downloading".
        for _ in range(20):
            if self.is_downloading(engine_id):
                break
            time.sleep(0.05)
        return self.status(spec)

    def _run_download(self, spec: EngineSpec) -> None:
        total = self._remote_total_bytes(spec)
        base = self._bytes_on_disk(spec)
        payload = json.dumps(
            [
                {
                    "repo": d.repo,
                    "revision": d.revision,
                    "allow_patterns": list(d.allow_patterns) if d.allow_patterns else None,
                }
                for d in spec.downloads
            ]
        )
        env = dict(os.environ)
        env["HF_HUB_DISABLE_XET"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")
        try:
            proc = subprocess.Popen(
                [self._python, "-c", _DOWNLOAD_SCRIPT, payload],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            with self._lock:
                self._jobs[spec.id] = {"error": f"Could not start the download: {exc}"}
            return
        with self._lock:
            self._jobs[spec.id].update(proc=proc, total_bytes=total, base_bytes=base)
        _, err = proc.communicate()
        with self._lock:
            job = self._jobs[spec.id]
            job["proc"] = None
            if proc.returncode != 0:
                tail = (err or "").strip().splitlines()[-1:] or ["unknown error"]
                job["error"] = f"Download failed: {tail[0][:300]}"
                logger.warning("engine download %s failed: %s", spec.id, (err or "")[-2000:])
            else:
                job.pop("error", None)

    def _remote_total_bytes(self, spec: EngineSpec) -> Optional[float]:
        """Sum of the files each download will fetch, from the Hub API.

        Best-effort: offline or rate-limited, progress falls back to the
        catalog's size estimate.
        """
        total = 0
        try:
            for d in spec.downloads:
                rev = d.revision or "main"
                resp = httpx.get(
                    f"https://huggingface.co/api/models/{d.repo}/tree/{rev}",
                    params={"recursive": "1"},
                    timeout=10.0,
                )
                resp.raise_for_status()
                for f in resp.json():
                    if f.get("type") != "file":
                        continue
                    path = f.get("path", "")
                    if d.allow_patterns and not any(fnmatch.fnmatch(path, p) for p in d.allow_patterns):
                        continue
                    total += int(f.get("size") or 0)
        except Exception:
            return None
        return float(total) or None

    # ----- remove -----

    def remove(self, engine_id: str) -> None:
        if engine_id == DEFAULT_ENGINE_ID:
            raise ValueError("Kokoro is Myna's fallback voice and can't be removed.")
        spec = self._catalog[engine_id]
        if self.is_downloading(engine_id):
            raise ValueError("That engine is still downloading.")
        shared = {
            d.repo
            for other in self._catalog.values()
            if other.id != engine_id
            for d in other.downloads
        }
        doomed = [repo_dir(d.repo, self.hub) for d in spec.downloads if d.repo not in shared]
        # Content in the hub-wide store may be shared with ANY other repo in
        # the cache (it is deduplicated by hash), so only delete targets no
        # surviving repo links to.
        targets = set()
        for root in doomed:
            targets |= {t for t in _blob_files(root) if not t.is_relative_to(root)}
        survivors = [r for r in self.hub.glob("models--*") if r not in doomed] if self.hub.exists() else []
        still_used = set()
        for root in survivors:
            still_used |= set(_blob_files(root))
        for root in doomed:
            shutil.rmtree(root, ignore_errors=True)
        for target in targets - still_used:
            try:
                target.unlink()
            except OSError:
                pass
        with self._lock:
            self._jobs.pop(engine_id, None)


def phys_footprint_mb(pid: int) -> Optional[float]:
    """A process's physical footprint — what Activity Monitor calls Memory.

    RSS undercounts an MLX process badly: the model's weights live in Metal
    buffers that RSS doesn't include (the live engine reported 58 MB RSS with
    Kokoro loaded). `proc_pid_rusage` → `ri_phys_footprint` counts them.
    """
    try:
        import ctypes
        import ctypes.util

        libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
        buf = ctypes.create_string_buffer(512)
        # RUSAGE_INFO_V2 = 2. rusage_info_v2: uuid[16], then u64 fields;
        # ri_phys_footprint is the 8th u64 → byte offset 16 + 7*8 = 72.
        if libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(2), buf) != 0:
            return None
        footprint = int.from_bytes(buf.raw[72:80], "little")
        return footprint / (1024 * 1024)
    except Exception:
        return None


def pid_listening_on(port: int) -> Optional[int]:
    """PID of the process with a TCP listener on `port`, via lsof."""
    lsof = shutil.which("lsof") or "/usr/sbin/lsof"
    try:
        out = subprocess.run(
            [lsof, "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True, text=True, timeout=3,
        ).stdout.split()
        return int(out[0]) if out else None
    except Exception:
        return None
