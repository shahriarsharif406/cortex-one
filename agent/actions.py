"""The allowlist: the ONLY things Cortex One can do on the computer.

Nothing here accepts a free-form shell command. Files are confined to
``allowed_roots``, apps to ``allowed_apps`` and scripts to
``approved_scripts`` (all set by the owner in config.json).
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .config import Settings

MAX_PARAM_LEN = 500
MAX_LIST = 200
MAX_WALK = 20_000


class ActionError(Exception):
    """A safe, user-presentable failure."""


@dataclass
class ActionResult:
    ok: bool
    message: str
    data: dict[str, Any] = field(default_factory=dict)


# ------------------------------------------------------------- processes
class ProcessManager:
    """Runs commands (shell=False) and can kill everything in an emergency."""

    def __init__(self) -> None:
        self._procs: set[subprocess.Popen] = set()
        self._lock = threading.Lock()

    def run(self, cmd: list[str], timeout: float = 60) -> tuple[int, str]:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        with self._lock:
            self._procs.add(proc)
        try:
            out, _ = proc.communicate(timeout=timeout)
            return proc.returncode, (out or "")[-2000:]
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            return -1, "timed out"
        finally:
            with self._lock:
                self._procs.discard(proc)

    def terminate_all(self) -> int:
        with self._lock:
            procs = list(self._procs)
        for p in procs:
            try:
                p.kill()
            except OSError:
                pass
        return len(procs)


def _default_launcher(cmd: list[str]) -> None:
    subprocess.Popen(cmd)  # fire and forget; no shell


@dataclass
class Context:
    settings: Settings
    processes: ProcessManager = field(default_factory=ProcessManager)
    runner: Callable[[list[str], float], tuple[int, str]] | None = None
    launcher: Callable[[list[str]], None] = _default_launcher
    system: str = field(default_factory=platform.system)
    stop_event: threading.Event = field(default_factory=threading.Event)

    def run(self, cmd: list[str], timeout: float = 60) -> tuple[int, str]:
        fn = self.runner or self.processes.run
        return fn(cmd, timeout)

    def require_windows(self) -> None:
        if self.system != "Windows":
            raise ActionError("This action is only available on Windows.")


# ------------------------------------------------------------ path safety
def resolve_allowed(path: str, roots: list[Path]) -> Path:
    if not roots:
        raise ActionError("No folders are allowed yet. Set allowed_roots in config.json.")
    try:
        p = Path(path).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        raise ActionError("Invalid path.")
    for root in roots:
        r = Path(root).expanduser().resolve()
        if p == r or r in p.parents:
            return p
    raise ActionError("That path is outside the allowed folders.")


# ---------------------------------------------------------------- actions
def status(ctx: Context, params: dict[str, Any]) -> ActionResult:
    data: dict[str, Any] = {
        "host": platform.node(),
        "system": ctx.system,
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    try:
        import psutil

        data["cpu_percent"] = psutil.cpu_percent(interval=0.2)
        vm = psutil.virtual_memory()
        data["ram_percent"] = vm.percent
        data["ram_free_mb"] = round(vm.available / 1_048_576)
        data["uptime_minutes"] = round((time.time() - psutil.boot_time()) / 60)
        battery = psutil.sensors_battery()
        if battery is not None:
            data["battery_percent"] = round(battery.percent)
            data["plugged_in"] = bool(battery.power_plugged)
    except Exception:  # psutil missing or unsupported sensor
        pass
    try:
        du = shutil.disk_usage(Path.home().anchor or "/")
        data["disk_free_gb"] = round(du.free / 1_073_741_824, 1)
    except OSError:
        pass
    return ActionResult(True, "ok", data)


def lock(ctx: Context, params: dict[str, Any]) -> ActionResult:
    ctx.require_windows()
    code, out = ctx.run(["rundll32.exe", "user32.dll,LockWorkStation"], 10)
    return ActionResult(code == 0, "Locked." if code == 0 else f"Lock failed: {out}")


def shutdown(ctx: Context, params: dict[str, Any]) -> ActionResult:
    ctx.require_windows()
    delay = ctx.settings.shutdown_delay_seconds
    code, out = ctx.run(["shutdown", "/s", "/t", str(delay)], 10)
    msg = (f"Shutting down in {delay}s. Send cancel_shutdown to abort."
           if code == 0 else f"Shutdown failed: {out}")
    return ActionResult(code == 0, msg, {"delay_seconds": delay})


def restart(ctx: Context, params: dict[str, Any]) -> ActionResult:
    ctx.require_windows()
    delay = ctx.settings.shutdown_delay_seconds
    code, out = ctx.run(["shutdown", "/r", "/t", str(delay)], 10)
    msg = (f"Restarting in {delay}s. Send cancel_shutdown to abort."
           if code == 0 else f"Restart failed: {out}")
    return ActionResult(code == 0, msg, {"delay_seconds": delay})


def cancel_shutdown(ctx: Context, params: dict[str, Any]) -> ActionResult:
    ctx.require_windows()
    code, out = ctx.run(["shutdown", "/a"], 10)
    # exit code 1116 = "no shutdown in progress"; that is fine.
    ok = code in (0, 1116)
    return ActionResult(ok, "Shutdown cancelled." if code == 0
                        else "No shutdown was pending." if ok else f"Failed: {out}")


def emergency_stop(ctx: Context, params: dict[str, Any]) -> ActionResult:
    ctx.stop_event.set()
    killed = ctx.processes.terminate_all()
    pending = ""
    if ctx.system == "Windows":
        code, _ = ctx.run(["shutdown", "/a"], 10)
        pending = " Pending shutdown cancelled." if code == 0 else ""
    return ActionResult(True, f"Stopped {killed} running task(s).{pending}",
                        {"killed": killed})


def list_files(ctx: Context, params: dict[str, Any]) -> ActionResult:
    folder = resolve_allowed(params["path"], ctx.settings.allowed_roots)
    if not folder.is_dir():
        raise ActionError("Not a folder.")
    entries = []
    for item in sorted(folder.iterdir(), key=lambda p: p.name.lower())[:MAX_LIST]:
        entries.append({"name": item.name, "dir": item.is_dir(),
                        "size": item.stat().st_size if item.is_file() else None})
    return ActionResult(True, f"{len(entries)} item(s).",
                        {"path": str(folder), "entries": entries})


def find_files(ctx: Context, params: dict[str, Any]) -> ActionResult:
    root = resolve_allowed(params["root"], ctx.settings.allowed_roots)
    query = params["query"].lower().strip()
    if not query:
        raise ActionError("Empty search.")
    found: list[str] = []
    seen = 0
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames + dirnames:
            seen += 1
            if query in name.lower():
                found.append(str(Path(dirpath) / name))
            if len(found) >= 50 or seen >= MAX_WALK:
                return ActionResult(True, f"{len(found)} match(es) (truncated).",
                                    {"matches": found, "truncated": True})
    return ActionResult(True, f"{len(found)} match(es).", {"matches": found})


def copy_file(ctx: Context, params: dict[str, Any]) -> ActionResult:
    src = resolve_allowed(params["src"], ctx.settings.allowed_roots)
    dst = resolve_allowed(params["dst"], ctx.settings.allowed_roots)
    if not src.is_file():
        raise ActionError("Source is not a file.")
    if dst.exists():
        raise ActionError("Destination already exists; nothing was overwritten.")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return ActionResult(True, "Copied.", {"dst": str(dst)})


def make_folder(ctx: Context, params: dict[str, Any]) -> ActionResult:
    path = resolve_allowed(params["path"], ctx.settings.allowed_roots)
    path.mkdir(parents=True, exist_ok=True)
    return ActionResult(True, "Folder ready.", {"path": str(path)})


def open_app(ctx: Context, params: dict[str, Any]) -> ActionResult:
    name = params["name"].lower().strip()
    cmd = ctx.settings.allowed_apps.get(name)
    if not cmd:
        raise ActionError(
            f"'{name}' is not an approved app. Approved: "
            f"{', '.join(sorted(ctx.settings.allowed_apps)) or 'none'}.")
    ctx.require_windows()
    ctx.launcher(list(cmd))
    return ActionResult(True, f"Opened {name}.")


def run_script(ctx: Context, params: dict[str, Any]) -> ActionResult:
    name = params["name"].strip()
    cmd = ctx.settings.approved_scripts.get(name)
    if not cmd:
        raise ActionError(
            f"'{name}' is not an approved script. Approved: "
            f"{', '.join(sorted(ctx.settings.approved_scripts)) or 'none'}.")
    if ctx.stop_event.is_set():
        raise ActionError("Emergency stop is active. Restart the agent to continue.")
    code, out = ctx.run(list(cmd), 120)
    return ActionResult(code == 0, out.strip()[-800:] or ("done" if code == 0 else "failed"),
                        {"exit_code": code})


# --------------------------------------------------------------- registry
@dataclass(frozen=True)
class ActionSpec:
    name: str
    description: str
    risk: str  # "low" or "high" (high needs two-step confirmation over HTTP)
    handler: Callable[[Context, dict[str, Any]], ActionResult]
    params: tuple[str, ...] = ()


REGISTRY: dict[str, ActionSpec] = {s.name: s for s in [
    ActionSpec("status", "CPU, RAM, battery, disk, uptime", "low", status),
    ActionSpec("lock", "Lock the screen", "low", lock),
    ActionSpec("shutdown", "Shut down after a short delay", "high", shutdown),
    ActionSpec("restart", "Restart after a short delay", "high", restart),
    ActionSpec("cancel_shutdown", "Cancel a pending shutdown/restart", "low",
               cancel_shutdown),
    ActionSpec("emergency_stop", "Kill running tasks and cancel shutdown", "low",
               emergency_stop),
    ActionSpec("list_files", "List a folder inside the allowed folders", "low",
               list_files, ("path",)),
    ActionSpec("find_files", "Find files by name in an allowed folder", "low",
               find_files, ("root", "query")),
    ActionSpec("copy_file", "Copy a file (never overwrites)", "low", copy_file,
               ("src", "dst")),
    ActionSpec("make_folder", "Create a folder in an allowed folder", "low",
               make_folder, ("path",)),
    ActionSpec("open_app", "Open an approved app", "low", open_app, ("name",)),
    ActionSpec("run_script", "Run a pre-approved script by name", "high",
               run_script, ("name",)),
]}


def validate_params(spec: ActionSpec, params: dict[str, Any]) -> dict[str, str]:
    unknown = set(params) - set(spec.params)
    if unknown:
        raise ActionError(f"Unknown parameter(s): {', '.join(sorted(unknown))}.")
    clean: dict[str, str] = {}
    for key in spec.params:
        value = params.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ActionError(f"Missing parameter: {key}.")
        if len(value) > MAX_PARAM_LEN or "\x00" in value:
            raise ActionError(f"Invalid parameter: {key}.")
        clean[key] = value
    return clean
