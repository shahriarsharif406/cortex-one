"""Supervised GUI-agent mode (session 2, phase 7). OFF by default.

!!! UNVERIFIED ON A REAL SCREEN. Everything here is tested with fake backends only: the real
mouse, keyboard and screen code (ctypes, bottom of this file) has never been run. !!!

The AI may operate the mouse and keyboard ONLY inside a GUI session that the owner approved:

* the session is started by the high-risk action ``gui_session_start(minutes)``, which needs the
  two-step confirmation (and the phone's biometric); the AI can only request it;
* it lasts at most ``max_session_minutes`` and ``max_actions`` actions, and ends at once on
  ``emergency_stop``, on the STOP button, on any error, or after too many refused actions;
* every input needs the FOREGROUND window to belong to ``allowed_apps``; windows of
  ``blocked_apps`` and titles containing ``blocked_title_patterns`` refuse input and screenshots
  (defence in depth: a title/process list is weak, not a guarantee);
* typing is refused when the focused field is detectably a password box; text is capped and has
  no control characters; keys come from a FIXED list; clicks must fall inside the foreground
  window and inside the screenshot the model was shown;
* everything the screen shows is untrusted data.

Nothing is configurable by the phone or the AI except the number of minutes of a session.
"""
from __future__ import annotations

import base64
import io
import logging
import re
import secrets
import threading
import time
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Protocol

log = logging.getLogger("cortex.gui")

# built-in blocklists: the owner can ADD to them, never remove
DEFAULT_BLOCKED_TITLES = ("bank", "wallet", "password", "passcode", "login", "log in", "sign in",
                          "signin", "2fa", "otp", "one-time", "credential", "paypal", "bkash",
                          "nagad", "rocket", "binance", "metamask", "credit card", "cvv")
DEFAULT_BLOCKED_APPS = ("keepass", "keepassxc", "bitwarden", "1password", "lastpass", "dashlane",
                        "nordpass", "roboform", "enpass", "authy", "authenticator", "mstsc",
                        "powershell", "pwsh", "cmd", "regedit", "taskmgr", "mmc", "windowsterminal")

MAX_TYPE_CHARS = 200
MAX_SCROLL = 20
MAX_COORD = 20000
SHOT_MAX_SIDE = 1024
KEEP_SHOTS = 100
MAX_LOG = 200
MAX_REFUSALS = 10
NAME_RE = re.compile(r"[a-z0-9_.-]{1,40}")
SHOT_RE = re.compile(r"gui-[0-9a-f]{8}-[0-9]{1,4}\.(jpg|png)")

# Fixed key list. Value = virtual-key codes pressed together (modifiers first).
VK_CTRL, VK_SHIFT = 0x11, 0x10
KEYS: dict[str, tuple[int, ...]] = {
    "enter": (0x0D,), "tab": (0x09,), "shift+tab": (VK_SHIFT, 0x09), "esc": (0x1B,),
    "up": (0x26,), "down": (0x28,), "left": (0x25,), "right": (0x27,),
    "backspace": (0x08,), "delete": (0x2E,), "home": (0x24,), "end": (0x23,),
    "pageup": (0x21,), "pagedown": (0x22,), "space": (0x20,), "f5": (0x74,),
    "ctrl+a": (VK_CTRL, 0x41), "ctrl+c": (VK_CTRL, 0x43), "ctrl+v": (VK_CTRL, 0x56),
    "ctrl+x": (VK_CTRL, 0x58), "ctrl+z": (VK_CTRL, 0x5A), "ctrl+y": (VK_CTRL, 0x59),
    "ctrl+s": (VK_CTRL, 0x53), "ctrl+f": (VK_CTRL, 0x46),
}
GUI_INPUT_TOOLS = frozenset({"gui_screenshot", "gui_click", "gui_double_click", "gui_type",
                             "gui_key", "gui_scroll"})


class GuiError(Exception):
    """A refusal with a message that is safe to show."""


# --------------------------------------------------------------------- providers
@dataclass(frozen=True)
class Foreground:
    process: str                        # base name, lower case, no .exe
    title: str
    rect: tuple[int, int, int, int]     # left, top, right, bottom in screen pixels
    focus_password: bool | None = None  # True / False when detectable, None when not


class Backend(Protocol):
    def screen_size(self) -> tuple[int, int]: ...
    def capture(self) -> tuple[int, int, bytes]: ...         # width, height, BGRA pixels
    def click(self, x: int, y: int, double: bool) -> None: ...
    def type_text(self, text: str) -> None: ...
    def key(self, vks: tuple[int, ...]) -> None: ...
    def scroll(self, clicks: int) -> None: ...


class ForegroundProvider(Protocol):
    def get(self) -> Foreground | None: ...


# ----------------------------------------------------------------------- policy
def _clamp(v: Any, default: int, lo: int, hi: int) -> int:
    if isinstance(v, bool) or not isinstance(v, int):
        return default
    return max(lo, min(v, hi))


def _names(raw: Any) -> frozenset[str]:
    if not isinstance(raw, (list, tuple)):
        return frozenset()
    out = set()
    for item in raw:
        if isinstance(item, str):
            n = item.strip().lower().removesuffix(".exe")
            if NAME_RE.fullmatch(n):
                out.add(n)
    return frozenset(out)


def _titles(raw: Any) -> tuple[str, ...]:
    if not isinstance(raw, (list, tuple)):
        return ()
    return tuple(sorted({t.strip().lower() for t in raw
                         if isinstance(t, str) and 2 <= len(t.strip()) <= 40}))


@dataclass(frozen=True)
class GuiPolicy:
    enabled: bool
    max_minutes: int
    max_actions: int
    allowed_apps: frozenset[str]
    blocked_apps: frozenset[str]
    blocked_titles: tuple[str, ...]

    @classmethod
    def from_settings(cls, settings: Any) -> "GuiPolicy":
        cfg = getattr(settings, "gui_agent", None)
        cfg = cfg if isinstance(cfg, dict) else {}
        allowed = _names(cfg.get("allowed_apps"))
        blocked_apps = _names(cfg.get("blocked_apps")) | frozenset(DEFAULT_BLOCKED_APPS)
        return cls(
            enabled=cfg.get("enabled") is True,
            max_minutes=_clamp(cfg.get("max_session_minutes"), 10, 1, 60),
            max_actions=_clamp(cfg.get("max_actions"), 60, 1, 300),
            allowed_apps=allowed - blocked_apps,       # a blocked app can never be allowed
            blocked_apps=blocked_apps,
            blocked_titles=tuple(sorted(set(DEFAULT_BLOCKED_TITLES) | set(_titles(cfg.get("blocked_title_patterns"))))),
        )

    def why_not(self, fg: Foreground | None, *, need_allowed: bool) -> str | None:
        """A reason this foreground window must not get input (or be shown), else None."""
        if fg is None:
            return "Cannot tell which window is in front."
        if fg.process in self.blocked_apps:
            return "A blocked app is in front."
        title = fg.title.lower()
        if any(p in title for p in self.blocked_titles):
            return "The window title looks sensitive (bank, password, login ...)."
        if need_allowed and fg.process not in self.allowed_apps:
            return f"'{fg.process}' is not an approved app for GUI control."
        return None


# ---------------------------------------------------------------------- the session
@dataclass
class GuiSession:
    id: str
    started: float
    deadline: float
    max_actions: int
    used: int = 0
    refused: int = 0
    ended: float | None = None
    reason: str = ""
    last_shot: dict[str, Any] | None = None     # {file, width, height, factor, media_type}
    shots: int = 0
    log: list[dict[str, Any]] = field(default_factory=list)


def downscale_bgra(bgra: bytes, w: int, h: int, factor: int) -> tuple[int, int, bytes]:
    """Nearest-neighbour shrink by an integer factor (pure Python, no dependency)."""
    if factor <= 1:
        return w, h, bgra
    from array import array

    px = array("I")
    px.frombytes(bgra[: w * h * 4])
    nw, nh = w // factor, h // factor
    out = array("I")
    for y in range(nh):
        row = px[(y * factor) * w:(y * factor) * w + w]
        out.extend(row[::factor][:nw])
    return nw, nh, out.tobytes()


def encode_shot(width: int, height: int, bgra: bytes) -> tuple[str, bytes]:
    """JPEG (Pillow, if installed) else PNG. Returns (media_type, bytes)."""
    try:
        from PIL import Image

        im = Image.frombytes("RGB", (width, height), bgra, "raw", "BGRX")
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=70, optimize=True)
        return "image/jpeg", buf.getvalue()
    except Exception:
        from .screen import encode_png

        return "image/png", encode_png(width, height, bgra)


class GuiController:
    """All GUI rules in one place. Backend, foreground provider and clock are injected."""

    def __init__(self, settings: Any, backend: Callable[[], Backend],
                 foreground: Callable[[], ForegroundProvider], stop_event: threading.Event,
                 clock: Callable[[], float] = time.time, shots_dir: Path | None = None,
                 encoder: Callable[[int, int, bytes], tuple[str, bytes]] = encode_shot):
        self.settings = settings
        self._backend_factory, self._foreground_factory = backend, foreground
        self.stop_event, self.clock, self.encoder = stop_event, clock, encoder
        self.shots_dir = shots_dir or (Path(settings.data_dir) / "gui_shots")
        self.session: GuiSession | None = None
        self._lock = threading.Lock()
        self._backend: Backend | None = None
        self._fg: ForegroundProvider | None = None

    # -- helpers --------------------------------------------------------------
    @property
    def policy(self) -> GuiPolicy:
        return GuiPolicy.from_settings(self.settings)

    def backend(self) -> Backend:
        if self._backend is None:
            self._backend = self._backend_factory()
        return self._backend

    def foreground(self) -> Foreground | None:
        if self._fg is None:
            self._fg = self._foreground_factory()
        return self._fg.get()

    def active(self) -> bool:
        with self._lock:
            return self._active_locked()

    def _active_locked(self) -> bool:
        s = self.session
        if s is None or s.ended is not None:
            return False
        if self.stop_event.is_set():
            self._end_locked("emergency stop")
            return False
        if self.clock() >= s.deadline:
            self._end_locked("time limit reached")
            return False
        return True

    def _end_locked(self, reason: str) -> None:
        s = self.session
        if s is not None and s.ended is None:
            s.ended, s.reason = self.clock(), reason

    def end(self, reason: str) -> bool:
        with self._lock:
            was = self.session is not None and self.session.ended is None
            self._end_locked(reason)
            return was

    # -- starting -------------------------------------------------------------
    def start(self, minutes: int) -> GuiSession:
        pol = self.policy
        if not pol.enabled:
            raise GuiError("GUI control is switched off (gui_agent.enabled in config.json).")
        if not pol.allowed_apps:
            raise GuiError("No app is approved for GUI control (gui_agent.allowed_apps).")
        if self.stop_event.is_set():
            raise GuiError("Emergency stop is active. Restart the agent to continue.")
        if not 1 <= minutes <= pol.max_minutes:
            raise GuiError(f"minutes must be 1 to {pol.max_minutes}.")
        with self._lock:
            if self._active_locked():
                raise GuiError("A GUI session is already running.")
            now = self.clock()
            self.session = GuiSession(secrets.token_hex(4), now, now + minutes * 60, pol.max_actions)
            self.shots_dir.mkdir(parents=True, exist_ok=True)
            return self.session

    # -- one gate for every action ---------------------------------------------
    def _begin(self, name: str, need_allowed: bool = True) -> tuple[GuiSession, Foreground | None]:
        with self._lock:
            if not self._active_locked():
                raise GuiError("No GUI session is active. The owner must start one on the phone.")
            s = self.session
            assert s is not None
            if s.used >= s.max_actions:
                self._end_locked("action limit reached")
                raise GuiError("The GUI session has used all its actions.")
        try:
            fg = self.foreground()
        except Exception:
            self.end("error")
            raise GuiError("The window check failed; the GUI session was ended.")
        problem = self.policy.why_not(fg, need_allowed=need_allowed)
        if problem:
            self._refused(s, name, problem)
            raise GuiError(problem)
        return s, fg

    def _refused(self, s: GuiSession, name: str, why: str) -> None:
        with self._lock:
            s.refused += 1
            self._add_log(s, name, False, why)
            if s.refused >= MAX_REFUSALS:
                self._end_locked("too many refused actions")

    def _add_log(self, s: GuiSession, name: str, ok: bool, detail: str, shot: str | None = None) -> None:
        s.log.append({"n": len(s.log) + 1, "action": name, "ok": ok, "detail": detail[:120],
                      "shot": shot, "t": int(self.clock())})
        del s.log[:-MAX_LOG]

    def _finish(self, s: GuiSession, name: str, detail: str, take_shot: bool = True) -> str | None:
        """Count the action, store a small reference picture, end the session at the limit."""
        shot = None
        if take_shot:
            try:
                shot = self._save_shot(s)
            except Exception:
                shot = None
        with self._lock:
            s.used += 1
            self._add_log(s, name, True, detail, shot)
            if s.used >= s.max_actions:
                self._end_locked("action limit reached")
        return shot

    def _fail(self, s: GuiSession, name: str) -> GuiError:
        """Any backend error ends the session (the owner can start a new one)."""
        with self._lock:
            self._add_log(s, name, False, "error")
            self._end_locked("error")
        return GuiError("The GUI action failed; the GUI session was ended.")

    # -- pictures -----------------------------------------------------------------
    def _capture_small(self, s: GuiSession) -> tuple[str, bytes, int, int, int]:
        w, h, bgra = self.backend().capture()
        factor = max(1, -(-max(w, h) // SHOT_MAX_SIDE))
        nw, nh, small = downscale_bgra(bgra, w, h, factor)
        media, data = self.encoder(nw, nh, small)
        return media, data, nw, nh, factor

    def _save_shot(self, s: GuiSession) -> str:
        media, data, nw, nh, factor = self._capture_small(s)
        s.shots += 1
        name = f"gui-{s.id}-{s.shots}.{'jpg' if media == 'image/jpeg' else 'png'}"
        (self.shots_dir / name).write_bytes(data)
        s.last_shot = {"file": name, "width": nw, "height": nh, "factor": factor, "media_type": media}
        self._prune()
        return name

    def _prune(self) -> None:
        try:
            files = sorted((p for p in self.shots_dir.iterdir() if SHOT_RE.fullmatch(p.name)),
                           key=lambda p: p.stat().st_mtime)
            for p in files[:-KEEP_SHOTS]:
                p.unlink()
        except OSError:
            pass

    # -- the actions ----------------------------------------------------------------
    def screenshot(self) -> dict[str, Any]:
        s, _fg = self._begin("gui_screenshot", need_allowed=False)   # shown unless a blocked window is in front
        try:
            media, data, nw, nh, factor = self._capture_small(s)
            with self._lock:
                s.shots += 1
                name = f"gui-{s.id}-{s.shots}.{'jpg' if media == 'image/jpeg' else 'png'}"
                s.last_shot = {"file": name, "width": nw, "height": nh, "factor": factor, "media_type": media}
            self.shots_dir.mkdir(parents=True, exist_ok=True)
            (self.shots_dir / name).write_bytes(data)
            self._prune()
        except GuiError:
            raise
        except Exception:
            raise self._fail(s, "gui_screenshot")
        with self._lock:
            s.used += 1
            self._add_log(s, "gui_screenshot", True, f"{nw}x{nh}", name)
            if s.used >= s.max_actions:
                self._end_locked("action limit reached")
        return {"media_type": media, "data_b64": base64.b64encode(data).decode("ascii"),
                "width": nw, "height": nh, "file": name}

    def _point(self, s: GuiSession, fg: Foreground, x: int, y: int) -> tuple[int, int]:
        shot = s.last_shot
        if shot is None:
            self._refused(s, "click", "no screenshot yet")
            raise GuiError("Take a screenshot first: coordinates are pixels of that picture.")
        if not (0 <= x < shot["width"] and 0 <= y < shot["height"]):
            self._refused(s, "click", "outside the picture")
            raise GuiError(f"The point is outside the picture ({shot['width']}x{shot['height']}).")
        rx, ry = x * shot["factor"], y * shot["factor"]
        sw, sh = self.backend().screen_size()
        left, top, right, bottom = fg.rect
        if not (0 <= rx < sw and 0 <= ry < sh) or not (left <= rx < right and top <= ry < bottom):
            self._refused(s, "click", "outside the front window")
            raise GuiError("The point is outside the window that is in front.")
        return rx, ry

    def click(self, x: int, y: int, double: bool = False) -> str | None:
        name = "gui_double_click" if double else "gui_click"
        s, fg = self._begin(name)
        assert fg is not None
        rx, ry = self._point(s, fg, x, y)
        try:
            self.backend().click(rx, ry, double)
        except Exception:
            raise self._fail(s, name)
        return self._finish(s, name, f"({x},{y})")

    def type_text(self, text: str) -> str | None:
        s, fg = self._begin("gui_type")
        assert fg is not None
        if not text or len(text) > MAX_TYPE_CHARS or any(ord(c) < 0x20 or ord(c) == 0x7F for c in text):
            self._refused(s, "gui_type", "bad text")
            raise GuiError(f"Text must be 1 to {MAX_TYPE_CHARS} printable characters (no control characters).")
        if fg.focus_password is True:
            self._refused(s, "gui_type", "password field")
            raise GuiError("The focused field looks like a password box. Nothing was typed.")
        try:
            self.backend().type_text(text)
        except Exception:
            raise self._fail(s, "gui_type")
        return self._finish(s, "gui_type", f"{len(text)} characters")     # the text itself is never logged

    def key(self, name: str) -> str | None:
        s, _fg = self._begin("gui_key")
        vks = KEYS.get(name.strip().lower())
        if vks is None:
            self._refused(s, "gui_key", "unknown key")
            raise GuiError(f"Unknown key. Allowed: {', '.join(KEYS)}.")
        try:
            self.backend().key(vks)
        except Exception:
            raise self._fail(s, "gui_key")
        return self._finish(s, "gui_key", name.strip().lower())

    def scroll(self, clicks: int) -> str | None:
        s, _fg = self._begin("gui_scroll")
        if clicks == 0 or abs(clicks) > MAX_SCROLL:
            self._refused(s, "gui_scroll", "bad amount")
            raise GuiError(f"Scroll by 1 to {MAX_SCROLL} clicks (negative = down).")
        try:
            self.backend().scroll(clicks)
        except Exception:
            raise self._fail(s, "gui_scroll")
        return self._finish(s, "gui_scroll", str(clicks))

    # -- read-only view for the phone -----------------------------------------------------
    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            active = self._active_locked()
            s = self.session
            if s is None:
                return {"active": False, "enabled": self.policy.enabled}
            now = self.clock()
            return {"active": active, "enabled": self.policy.enabled, "id": s.id,
                    "remaining_seconds": max(0, int(s.deadline - now)) if active else 0,
                    "actions_used": s.used, "max_actions": s.max_actions,
                    "ended_reason": "" if active else s.reason,
                    "last_shot": (s.last_shot or {}).get("file"),
                    "actions": list(s.log[-30:])}

    def shot_bytes(self, name: str) -> tuple[bytes, str] | None:
        """Only files this controller wrote, by a strict name. None if absent."""
        if not SHOT_RE.fullmatch(name or ""):
            return None
        p = self.shots_dir / name
        try:
            if p.is_symlink() or not p.is_file() or p.stat().st_size > 4_000_000:
                return None
            data = p.read_bytes()
        except OSError:
            return None
        if data.startswith(b"\xff\xd8\xff"):
            return data, "image/jpeg"
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            return data, "image/png"
        return None


# ===========================================================================
# Real Windows implementations (ctypes). NEVER used by the tests: tests inject fakes, and
# conftest makes the default factories raise. UNVERIFIED on a real screen.
# ===========================================================================
def default_backend() -> Backend:
    return WindowsBackend()


def default_foreground() -> ForegroundProvider:
    return WindowsForeground()


class WindowsBackend:  # pragma: no cover - needs a real desktop
    def __init__(self) -> None:
        import ctypes

        self.ctypes = ctypes
        self.user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        try:
            self.user32.SetProcessDPIAware()
        except Exception:
            pass

    def screen_size(self) -> tuple[int, int]:
        return int(self.user32.GetSystemMetrics(0)), int(self.user32.GetSystemMetrics(1))

    def capture(self) -> tuple[int, int, bytes]:
        import ctypes
        from ctypes import wintypes

        user32 = self.user32
        gdi32 = ctypes.windll.gdi32  # type: ignore[attr-defined]
        w, h = self.screen_size()
        if w <= 0 or h <= 0 or w * h > 40_000_000:
            raise OSError("no usable screen")
        dc = user32.GetDC(None)
        mem = gdi32.CreateCompatibleDC(dc)
        bmp = gdi32.CreateCompatibleBitmap(dc, w, h)
        old = gdi32.SelectObject(mem, bmp)

        class BIH(ctypes.Structure):
            _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                        ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                        ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                        ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]

        try:
            if not gdi32.BitBlt(mem, 0, 0, w, h, dc, 0, 0, 0x00CC0020):
                raise OSError("capture failed")
            header = BIH(ctypes.sizeof(BIH), w, -h, 1, 32, 0)
            buf = ctypes.create_string_buffer(w * h * 4)
            if not gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(header), 0):
                raise OSError("cannot read pixels")
            return w, h, buf.raw
        finally:
            gdi32.SelectObject(mem, old)
            gdi32.DeleteObject(bmp)
            gdi32.DeleteDC(mem)
            user32.ReleaseDC(None, dc)

    # -- input -------------------------------------------------------------------
    def _send(self, inputs) -> None:
        import ctypes

        arr = (type(inputs[0]) * len(inputs))(*inputs)
        if self.user32.SendInput(len(inputs), arr, ctypes.sizeof(type(inputs[0]))) != len(inputs):
            raise OSError("input was blocked")

    def _structs(self):
        import ctypes
        from ctypes import wintypes

        class MOUSEINPUT(ctypes.Structure):
            _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                        ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                        ("dwExtraInfo", ctypes.c_size_t)]

        class KEYBDINPUT(ctypes.Structure):
            _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

        class _U(ctypes.Union):
            _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]

        class INPUT(ctypes.Structure):
            _fields_ = [("type", wintypes.DWORD), ("u", _U)]

        return MOUSEINPUT, KEYBDINPUT, INPUT

    def click(self, x: int, y: int, double: bool) -> None:
        _MI, _KI, INPUT = self._structs()
        self.user32.SetCursorPos(int(x), int(y))
        for _ in range(2 if double else 1):
            down, up = INPUT(0), INPUT(0)
            down.u.mi.dwFlags, up.u.mi.dwFlags = 0x0002, 0x0004      # LEFTDOWN, LEFTUP
            self._send([down, up])
            time.sleep(0.05)

    def type_text(self, text: str) -> None:
        _MI, _KI, INPUT = self._structs()
        for ch in text:
            for flags in (0x0004, 0x0004 | 0x0002):                    # UNICODE down, UNICODE up
                i = INPUT(1)
                i.u.ki.wScan, i.u.ki.dwFlags = ord(ch), flags
                self._send([i])
            time.sleep(0.01)

    def key(self, vks: tuple[int, ...]) -> None:
        _MI, _KI, INPUT = self._structs()
        seq = []
        for vk in vks:
            i = INPUT(1)
            i.u.ki.wVk = vk
            seq.append(i)
        for vk in reversed(vks):
            i = INPUT(1)
            i.u.ki.wVk, i.u.ki.dwFlags = vk, 0x0002                     # KEYUP
            seq.append(i)
        self._send(seq)

    def scroll(self, clicks: int) -> None:
        _MI, _KI, INPUT = self._structs()
        i = INPUT(0)
        i.u.mi.dwFlags = 0x0800                                          # WHEEL
        i.u.mi.mouseData = (clicks * 120) & 0xFFFFFFFF
        self._send([i])


class WindowsForeground:  # pragma: no cover - needs a real desktop
    def get(self) -> Foreground | None:
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return None
        buf = ctypes.create_unicode_buffer(300)
        user32.GetWindowTextW(hwnd, buf, 300)
        pid = wintypes.DWORD()
        tid = user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        rect = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        try:
            import psutil

            name = psutil.Process(pid.value).name().lower().removesuffix(".exe")
        except Exception:
            return None

        class GUITHREADINFO(ctypes.Structure):
            _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                        ("hwndActive", wintypes.HWND), ("hwndFocus", wintypes.HWND),
                        ("hwndCapture", wintypes.HWND), ("hwndMenuOwner", wintypes.HWND),
                        ("hwndMoveSize", wintypes.HWND), ("hwndCaret", wintypes.HWND),
                        ("rcCaret", wintypes.RECT)]

        password: bool | None = None
        info = GUITHREADINFO()
        info.cbSize = ctypes.sizeof(GUITHREADINFO)
        if user32.GetGUIThreadInfo(tid, ctypes.byref(info)) and info.hwndFocus:
            cls = ctypes.create_unicode_buffer(80)
            user32.GetClassNameW(info.hwndFocus, cls, 80)
            if cls.value.lower() == "edit":      # classic edit control: ES_PASSWORD style bit
                password = bool(user32.GetWindowLongW(info.hwndFocus, -16) & 0x20)
        return Foreground(name, buf.value, (rect.left, rect.top, rect.right, rect.bottom), password)
