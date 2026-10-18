"""Coding sessions and the remote-desktop helper (session 2, phase 6).

``coding_projects`` in config.json is chosen by the OWNER:

    "coding_projects": {"api": {"path": "C:\\\\Users\\\\me\\\\Documents\\\\api",
                                "argv": ["C:\\\\Program Files\\\\Windows Terminal\\\\wt.exe", "claude"]}}

The phone and the AI only ever name a project. They never send a path, a program or an
argument. Starting needs the two-step confirmation (the AI can only request it); stopping only
touches sessions THIS agent started and tracked. The processes are launched with shell=False
through the same ProcessManager that ``run_script`` uses, so ``emergency_stop`` ends them too.
"""
from __future__ import annotations

import logging
import re
import shutil
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

log = logging.getLogger("cortex.sessions")

NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}")
MAX_PROJECTS = 20
MAX_ARGV = 16
MAX_ARG_LEN = 300
MAX_RUNNING = 3


@dataclass(frozen=True)
class Project:
    name: str            # lower-cased
    path: Path
    argv: tuple[str, ...]


def parse_projects(settings: Any) -> tuple[dict[str, Project], list[str]]:
    """(valid projects by lower-cased name, problems). An invalid entry is dropped and never run."""
    from .actions import ActionError, resolve_allowed

    raw = getattr(settings, "coding_projects", None)
    if raw in (None, {}):
        return {}, []
    problems: list[str] = []
    if not isinstance(raw, dict):
        return {}, ["coding_projects must be an object {name: {path, argv}}"]
    out: dict[str, Project] = {}
    for key, entry in list(raw.items())[:MAX_PROJECTS]:
        label = str(key)[:40]
        if not isinstance(key, str) or not NAME_RE.fullmatch(key):
            problems.append(f"project '{label}': the name may use letters, digits, space, _ . - (max 40)")
            continue
        if not isinstance(entry, dict) or set(entry) - {"path", "argv"}:
            problems.append(f"project '{label}': needs exactly path and argv")
            continue
        path, argv = entry.get("path"), entry.get("argv")
        if not isinstance(path, str) or not path.strip():
            problems.append(f"project '{label}': path is missing")
            continue
        try:
            folder = resolve_allowed(path, settings.allowed_roots)
        except ActionError:
            problems.append(f"project '{label}': the folder must be inside allowed_roots")
            continue
        if not folder.is_dir():
            problems.append(f"project '{label}': the folder does not exist")
            continue
        if (not isinstance(argv, list) or not 1 <= len(argv) <= MAX_ARGV
                or any(not isinstance(a, str) or not a or len(a) > MAX_ARG_LEN or "\x00" in a
                       or "\n" in a or "\r" in a for a in argv)):
            problems.append(f"project '{label}': argv must be a short list of plain texts")
            continue
        exe = argv[0]
        found = exe if Path(exe).is_absolute() and Path(exe).is_file() else shutil.which(exe)
        if not found:
            problems.append(f"project '{label}': the program '{exe[:60]}' was not found")
            continue
        low = key.strip().lower()
        if low in out:
            problems.append(f"project '{label}': duplicate name")
            continue
        out[low] = Project(low, folder, tuple(argv))
    if len(raw) > MAX_PROJECTS:
        problems.append(f"only the first {MAX_PROJECTS} projects are used")
    return out, problems


@dataclass
class Session:
    name: str
    proc: Any
    started: float
    exit_code: int | None = None
    ended: float | None = None


class SessionManager:
    """Tracks only the processes it started itself (by project name)."""

    def __init__(self, processes, popen: Callable | None = None,
                 on_exit: Callable[[str, int | None], None] | None = None,
                 clock: Callable[[], float] = time.time):
        self.processes = processes          # ProcessManager: emergency_stop reaches these too
        self.popen = popen
        self.on_exit = on_exit
        self.clock = clock
        self.sessions: dict[str, Session] = {}
        self._lock = threading.Lock()

    def running(self) -> list[str]:
        with self._lock:
            return [n for n, s in self.sessions.items() if s.exit_code is None
                    and s.proc.poll() is None]

    def start(self, project: Project) -> int:
        from .actions import ActionError

        with self._lock:
            old = self.sessions.get(project.name)
            if old is not None and old.proc.poll() is None:
                raise ActionError(f"'{project.name}' is already running.")
            live = [s for s in self.sessions.values() if s.proc.poll() is None]
            if len(live) >= MAX_RUNNING:
                raise ActionError(f"At most {MAX_RUNNING} coding sessions can run at once.")
            try:
                proc = self.processes.spawn(list(project.argv), str(project.path), self.popen)
            except (OSError, ValueError) as exc:
                raise ActionError(f"Could not start the session ({type(exc).__name__}).")
            sess = Session(project.name, proc, self.clock())
            self.sessions[project.name] = sess
        threading.Thread(target=self._watch, args=(sess,), name=f"session-{project.name}",
                         daemon=True).start()
        return int(getattr(proc, "pid", 0) or 0)

    def _watch(self, sess: Session) -> None:
        try:
            code = sess.proc.wait()
        except Exception:
            code = None
        with self._lock:
            sess.exit_code = code if isinstance(code, int) else -1
            sess.ended = self.clock()
        if self.on_exit is not None:
            try:
                self.on_exit(sess.name, sess.exit_code)
            except Exception as exc:          # a notifier must never hurt the agent
                log.warning("session exit hook failed (%s)", type(exc).__name__)

    def stop(self, name: str) -> bool:
        """Ends a session this agent started (and its child processes). False if there is none."""
        with self._lock:
            sess = self.sessions.get(name)
        if sess is None or sess.proc.poll() is not None:
            return False
        self.processes.kill_tree(sess.proc)
        return True

    def status(self, name: str) -> dict[str, Any]:
        with self._lock:
            sess = self.sessions.get(name)
        if sess is None:
            return {"state": "not started"}
        code = sess.proc.poll()
        if code is None:
            return {"state": "running", "started": int(sess.started),
                    "minutes": max(0, int((self.clock() - sess.started) // 60))}
        return {"state": "exited", "exit_code": code, "started": int(sess.started)}


def precheck_high(settings: Any, name: str, params: dict[str, Any]) -> str | None:
    """A reason why a HIGH-risk request can never run, or None. Used by the HTTP layer and the
    AI layer so the owner is never asked to confirm something that is bound to fail."""
    if name == "run_script":
        script = params.get("name")
        if script not in settings.approved_scripts:
            return "That script is not approved."
    elif name in ("coding_session_start", "coding_session_stop"):
        projects, _ = parse_projects(settings)
        if str(params.get("name", "")).strip().lower() not in projects:
            return "That is not a configured coding project."
    elif name == "gui_session_start":
        from .gui import GuiPolicy

        pol = GuiPolicy.from_settings(settings)
        if not pol.enabled:
            return "GUI control is switched off (gui_agent.enabled in config.json)."
        if not pol.allowed_apps:
            return "No app is approved for GUI control (gui_agent.allowed_apps)."
        raw = str(params.get("minutes", "")).strip()
        if not raw.isascii() or not raw.isdigit() or not 1 <= int(raw) <= pol.max_minutes:
            return f"minutes must be 1 to {pol.max_minutes}."
    elif name == "remote_desktop_start":
        key = str(getattr(settings, "remote_desktop_app", "rustdesk")).strip().lower()
        if key not in {str(k).strip().lower() for k in settings.allowed_apps}:
            return "The remote desktop app is not in allowed_apps."
    return None


def file_version(path: str) -> str | None:
    """Product version of an .exe through the Windows version API (ctypes). None if unknown."""
    try:
        import ctypes
        from ctypes import wintypes

        version = ctypes.windll.version  # type: ignore[attr-defined]
        size = version.GetFileVersionInfoSizeW(path, None)
        if not size:
            return None
        buf = ctypes.create_string_buffer(size)
        if not version.GetFileVersionInfoW(path, 0, size, buf):
            return None
        ptr = ctypes.c_void_p()
        length = wintypes.UINT()
        if not version.VerQueryValueW(buf, "\\", ctypes.byref(ptr), ctypes.byref(length)) or not ptr.value:
            return None

        class FixedInfo(ctypes.Structure):
            _fields_ = [("sig", wintypes.DWORD), ("sv", wintypes.DWORD), ("fvms", wintypes.DWORD),
                        ("fvls", wintypes.DWORD)]

        info = FixedInfo.from_address(ptr.value)
        return f"{info.fvms >> 16}.{info.fvms & 0xFFFF}.{info.fvls >> 16}.{info.fvls & 0xFFFF}"
    except Exception:
        return None
