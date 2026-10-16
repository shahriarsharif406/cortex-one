"""Coding-agent watcher: tells the owner when a long-running program exits or a
log stalls / shows a keyword.

Rules come from ``settings.watch_rules`` (a list of objects):

    {"name": "coder-done",  "kind": "process_exit", "target": "claude", "minutes": 0}
    {"name": "coder-stuck", "kind": "log_stalled",  "target": "coder",  "minutes": 15}
    {"name": "coder-error", "kind": "log_pattern",  "target": "coder",  "pattern": "error"}

``target`` is a NAME from ``watched_programs`` (process rules) or ``allowed_logs``
(log rules); never a path. The watcher reads process names (psutil) and log
mtimes / newly appended bytes only. An alert carries just the rule name, the time
and a fixed sentence: log text never reaches the alerts table, the audit log, the
push message or the phone, so a hostile log line cannot inject instructions.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

log = logging.getLogger("cortex.watch")

KINDS = ("process_exit", "log_stalled", "log_pattern")
KIND_PROCESS, KIND_STALLED, KIND_PATTERN = KINDS
ALERT_KIND = {KIND_PROCESS: "watch_exit", KIND_STALLED: "watch_stalled",
              KIND_PATTERN: "watch_pattern"}
MAX_RULES = 20
MAX_MINUTES = 1440
MAX_PATTERN = 80
READ_CAP = 256 * 1024                   # bytes looked at per log per check
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}")
_PATTERN_OK = re.compile(r"[\x20-\x7eঀ-৿]{1,%d}" % MAX_PATTERN)


@dataclass(frozen=True)
class Rule:
    name: str
    kind: str
    target: str            # lower-cased program / log NAME
    minutes: int = 0
    pattern: str = ""      # lower-cased substring


def _clamp(value: Any, default: int, lo: int, hi: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return max(lo, min(value, hi))


def check_interval(settings) -> int:
    return _clamp(getattr(settings, "watch_check_seconds", 30), 30, 5, 3600)


def cooldown_seconds(settings) -> int:
    return _clamp(getattr(settings, "watch_cooldown_seconds", 600), 600, 30, 86400)


def parse_rules(settings) -> tuple[list[Rule], list[str]]:
    """Valid rules plus plain-text problems (never containing log or secret data)."""
    raw = getattr(settings, "watch_rules", [])
    if not isinstance(raw, list):
        return [], ["watch_rules must be a list"]
    programs = {str(p).strip().lower() for p in settings.watched_programs if str(p).strip()}
    logs = {str(k).strip().lower() for k in settings.allowed_logs}
    rules: list[Rule] = []
    problems: list[str] = []
    seen: set[str] = set()
    for i, item in enumerate(raw, 1):
        tag = f"rule #{i}"
        if i > MAX_RULES:
            problems.append(f"{tag}: too many rules (max {MAX_RULES})")
            break
        if not isinstance(item, dict):
            problems.append(f"{tag}: must be an object")
            continue
        name, kind, target = item.get("name"), item.get("kind"), item.get("target")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            problems.append(f"{tag}: name must be 1-40 letters/digits/space/_/./-")
            continue
        tag = f"rule '{name}'"
        if name.lower() in seen:
            problems.append(f"{tag}: duplicate name")
            continue
        if kind not in KINDS:
            problems.append(f"{tag}: kind must be one of {', '.join(KINDS)}")
            continue
        if not isinstance(target, str) or not target.strip():
            problems.append(f"{tag}: target is required")
            continue
        target = target.strip().lower()
        pool, pool_name = (programs, "watched_programs") if kind == KIND_PROCESS \
            else (logs, "allowed_logs")
        if target not in pool:
            problems.append(f"{tag}: target is not in {pool_name}")
            continue
        minutes = item.get("minutes", 0)
        if isinstance(minutes, bool) or not isinstance(minutes, int) \
                or not (0 if kind != KIND_STALLED else 1) <= minutes <= MAX_MINUTES:
            problems.append(f"{tag}: minutes must be "
                            f"{'1' if kind == KIND_STALLED else '0'}-{MAX_MINUTES}")
            continue
        pattern = ""
        if kind == KIND_PATTERN:
            pattern = item.get("pattern")
            if not isinstance(pattern, str) or not _PATTERN_OK.fullmatch(pattern) \
                    or not pattern.strip():
                problems.append(f"{tag}: pattern must be 1-{MAX_PATTERN} plain printable characters")
                continue
            pattern = pattern.lower()
        seen.add(name.lower())
        rules.append(Rule(name, kind, target, minutes, pattern))
    return rules, problems


# ------------------------------------------------------------- providers
def psutil_processes() -> set[str]:
    """Lower-cased names (no .exe) of running programs. Names only."""
    import psutil

    names: set[str] = set()
    for proc in psutil.process_iter(["name"]):
        base = str(proc.info.get("name") or "").lower()
        names.add(base[:-4] if base.endswith(".exe") else base)
    return names


def file_stat(path: str) -> tuple[int, float] | None:
    """(size, mtime) of a regular file, or None."""
    try:
        p = Path(path)
        if not p.is_file():
            return None
        st = p.stat()
        return st.st_size, st.st_mtime
    except OSError:
        return None


def read_chunk(path: str, offset: int, length: int) -> bytes:
    with open(path, "rb") as f:
        f.seek(offset)
        return f.read(length)


def _decode(raw: bytes) -> str:
    if raw.count(b"\x00") * 3 > len(raw):                       # UTF-16 log
        return raw[:len(raw) - len(raw) % 2].decode("utf-16-le", "replace").lower()
    return raw.decode("utf-8", "replace").lower()


class RuleWatcher:
    """One ``tick()`` evaluates every rule once. ``start()`` runs it on a timer."""

    MESSAGES = {KIND_PROCESS: "program exited",
                KIND_STALLED: "log unchanged for {minutes} min",
                KIND_PATTERN: "watched text appeared in the log"}

    def __init__(self, engine, notifier=None, *,
                 processes: Callable[[], set[str]] = psutil_processes,
                 stat: Callable[[str], tuple[int, float] | None] = file_stat,
                 reader: Callable[[str, int, int], bytes] = read_chunk,
                 clock: Callable[[], float] = time.time):
        self.engine, self.notifier = engine, notifier
        self.processes, self.stat, self.reader, self.clock = processes, stat, reader, clock
        self.stop = threading.Event()
        self._lock = threading.Lock()
        self._state: dict[str, dict[str, Any]] = {}
        self._last_alert: dict[str, float] = {}
        self._status: dict[str, str] = {}

    # -- configuration --------------------------------------------------------
    def rules(self) -> tuple[list[Rule], list[str]]:
        return parse_rules(self.engine.settings)

    def _log_path(self, rule: Rule) -> str | None:
        for k, v in self.engine.settings.allowed_logs.items():
            if str(k).strip().lower() == rule.target:
                return str(v)
        return None

    # -- one check ------------------------------------------------------------
    def tick(self) -> list[str]:
        """Evaluate all rules; returns the names of rules that alerted."""
        with self._lock:
            rules, _ = self.rules()
            names = {r.name for r in rules}
            for gone in [n for n in self._state if n not in names]:
                self._state.pop(gone, None)
                self._status.pop(gone, None)
            try:
                running = self.processes() if any(r.kind == KIND_PROCESS for r in rules) else set()
            except Exception:
                running = None                  # cannot tell: judge nothing this round
            fired: list[str] = []
            for rule in rules:
                try:
                    hit = self._evaluate(rule, running)
                except Exception as exc:        # one bad rule must not stop the others
                    log.warning("watch rule failed (%s)", type(exc).__name__)
                    self._status[rule.name] = "error"
                    continue
                if hit and self._alert(rule):
                    fired.append(rule.name)
            return fired

    def _evaluate(self, rule: Rule, running: set[str] | None) -> bool:
        st = self._state.setdefault(rule.name, {})
        now = self.clock()
        if rule.kind == KIND_PROCESS:
            if running is None:
                return False
            if rule.target in running:
                st["seen"], st["gone_since"], st["fired"] = True, None, False
                self._status[rule.name] = "running"
                return False
            if not st.get("seen"):
                self._status[rule.name] = "waiting"      # never saw it run: nothing exited
                return False
            st.setdefault("gone_since", None)
            if st["gone_since"] is None:
                st["gone_since"] = now
            self._status[rule.name] = "exited"
            if st.get("fired") or now - st["gone_since"] < rule.minutes * 60:
                return False
            st["fired"] = True
            return True

        path = self._log_path(rule)
        info = self.stat(path) if path else None
        if info is None:
            self._status[rule.name] = "missing"
            st["offset"] = None                          # restart cleanly when it appears
            st["fired"] = False
            return False
        size, mtime = info

        if rule.kind == KIND_STALLED:
            if st.get("mtime") != mtime:
                st["mtime"], st["fired"] = mtime, False
            if now - mtime >= rule.minutes * 60:
                self._status[rule.name] = "stalled"
                if st.get("fired"):
                    return False
                st["fired"] = True
                return True
            self._status[rule.name] = "active"
            return False

        # log_pattern: look only at bytes appended since the last check
        offset = st.get("offset")
        if offset is None or size < offset:              # first look / rotated or truncated
            st["offset"], st["carry"] = size - size % 2, ""
            self._status[rule.name] = "clear"
            return False
        if size - offset > READ_CAP:
            offset = size - READ_CAP
            offset -= offset % 2
            st["carry"] = ""
        if size == offset:
            return self._pattern_state(rule, now, False)
        raw = self.reader(path, offset, min(size - offset, READ_CAP))
        st["offset"] = offset + len(raw)
        text = st.get("carry", "") + _decode(raw)
        st["carry"] = text[-(len(rule.pattern) - 1):] if len(rule.pattern) > 1 else ""
        return self._pattern_state(rule, now, rule.pattern in text)

    def _pattern_state(self, rule: Rule, now: float, found: bool) -> bool:
        recent = now - self._last_alert.get(rule.name, -1e18) < cooldown_seconds(self.engine.settings)
        self._status[rule.name] = "matched" if (found or (recent and self._status.get(rule.name) == "matched")) else "clear"
        return found

    # -- alerting -------------------------------------------------------------
    def _alert(self, rule: Rule) -> bool:
        now = self.clock()
        last = self._last_alert.get(rule.name)
        if last is not None and now - last < cooldown_seconds(self.engine.settings):
            return False                                 # same rule, too soon: stay quiet
        self._last_alert[rule.name] = now
        message = f"{rule.name}: " + self.MESSAGES[rule.kind].format(minutes=rule.minutes)
        self.engine.alerts.add(ALERT_KIND[rule.kind], None, None, message)
        self.engine.audit.log("watcher", "watch", ALERT_KIND[rule.kind],
                              {"rule": rule.name}, "ok", message)
        if self.notifier is not None:
            try:
                self.notifier.notify(message, None, time.strftime("%H:%M"))
            except Exception:                            # never fatal
                log.warning("notifier raised %s", "error")
        return True

    # -- read-only view for GET /watch ------------------------------------------
    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            rules, problems = self.rules()
            items = [{"name": r.name, "kind": r.kind, "target": r.target,
                      "minutes": r.minutes,
                      "state": self._status.get(r.name, "waiting"),
                      "last_alert": self._last_alert.get(r.name)} for r in rules]
        return {"rules": items, "problems": problems,
                "alerts": self.engine.alerts.recent(20, scope="watch")}

    # -- thread -----------------------------------------------------------------
    def run_forever(self) -> None:
        interval = check_interval(self.engine.settings)
        while not self.stop.wait(interval):
            try:
                self.tick()
            except Exception as exc:
                log.warning("watch check failed (%s)", type(exc).__name__)

    def start(self) -> threading.Thread | None:
        rules, problems = self.rules()
        for p in problems:
            log.warning("watch_rules: %s", p)
        if not rules:
            return None
        t = threading.Thread(target=self.run_forever, name="rule-watch", daemon=True)
        t.start()
        return t
