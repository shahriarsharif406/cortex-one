"""Owner-defined schedules: named low-risk actions that run at set times.

Rules come from ``settings.schedules`` (config.json, edited by the owner only):

    {"name": "nightly-usage", "action": "disk_usage_report",
     "params": {"root": "D:\\\\Projects"}, "every_minutes": 1440}
    {"name": "morning-info",  "action": "system_info", "daily_at": "08:30"}

Safety: only ``risk="low"`` actions, never ``emergency_stop``; params are strings checked by the
normal action validation; the run goes through ``Engine.run_scheduled`` (reserved channel
``schedule``, re-checked there). The phone and the AI cannot create, change or trigger a
schedule. An alert carries only the schedule name and ok/failed, never the action output.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

from .actions import REGISTRY

log = logging.getLogger("cortex.schedule")

MAX_SCHEDULES = 20
MIN_EVERY, MAX_EVERY = 5, 10080            # minutes
EXCLUDED = frozenset({"emergency_stop"})
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}")
TIME_RE = re.compile(r"([01]\d|2[0-3]):([0-5]\d)")


@dataclass(frozen=True)
class Schedule:
    name: str
    action: str
    params: tuple[tuple[str, str], ...] = ()
    every_minutes: int = 0
    daily_at: str = ""            # "HH:MM" local time


def allowed_action(action: str) -> bool:
    spec = REGISTRY.get(action)
    return spec is not None and spec.risk == "low" and action not in EXCLUDED


def parse_schedules(settings) -> tuple[list[Schedule], list[str]]:
    raw = getattr(settings, "schedules", [])
    if not isinstance(raw, list):
        return [], ["schedules must be a list"]
    out: list[Schedule] = []
    problems: list[str] = []
    seen: set[str] = set()
    for i, item in enumerate(raw, 1):
        tag = f"schedule #{i}"
        if i > MAX_SCHEDULES:
            problems.append(f"{tag}: too many schedules (max {MAX_SCHEDULES})")
            break
        if not isinstance(item, dict):
            problems.append(f"{tag}: must be an object")
            continue
        name = item.get("name")
        action = item.get("action")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name) or name.lower() in seen:
            problems.append(f"{tag}: bad or duplicate name")
            continue
        if not isinstance(action, str) or not allowed_action(action):
            problems.append(f"{tag}: action must be a low-risk action")
            continue
        params = item.get("params", {})
        spec = REGISTRY[action]
        allowed_keys = set(spec.params) | set(spec.optional)
        if (not isinstance(params, dict) or set(params) - allowed_keys
                or not all(isinstance(v, str) for v in params.values())
                or not set(spec.params) <= set(params)):
            problems.append(f"{tag}: params do not match the action")
            continue
        every, daily = item.get("every_minutes"), item.get("daily_at")
        if (every is None) == (daily is None):
            problems.append(f"{tag}: give exactly one of every_minutes or daily_at")
            continue
        if every is not None:
            if (isinstance(every, bool) or not isinstance(every, int)
                    or not MIN_EVERY <= every <= MAX_EVERY):
                problems.append(f"{tag}: every_minutes must be {MIN_EVERY} to {MAX_EVERY}")
                continue
            sched = Schedule(name, action, tuple(sorted(params.items())), every_minutes=every)
        else:
            if not isinstance(daily, str) or not TIME_RE.fullmatch(daily):
                problems.append(f"{tag}: daily_at must look like 08:30")
                continue
            sched = Schedule(name, action, tuple(sorted(params.items())), daily_at=daily)
        seen.add(name.lower())
        out.append(sched)
    return out, problems


class Scheduler:
    """Checks every ``tick`` seconds. Last-run times are kept in the kv table so a restart
    after a power cut does not repeat a daily job and does not skip an overdue interval job
    forever (an overdue job runs once on the first tick)."""

    def __init__(self, engine, clock: Callable[[], float] = time.time, tick: int = 30):
        self.engine, self.clock, self.tick = engine, clock, tick
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def _key(self, s: Schedule) -> str:
        return f"schedule_last:{s.name.lower()}"

    def _last(self, s: Schedule) -> float:
        try:
            return float(self.engine.db.kv_get(self._key(s)) or 0)
        except (TypeError, ValueError):
            return 0.0

    def is_due(self, s: Schedule, now: float) -> bool:
        last = self._last(s)
        if s.every_minutes:
            return now - last >= s.every_minutes * 60
        lt = time.localtime(now)
        hh, mm = int(s.daily_at[:2]), int(s.daily_at[3:])
        today_slot = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, hh, mm, 0, 0, 0, -1))
        return now >= today_slot and last < today_slot

    def run_due(self) -> list[str]:
        schedules, _ = parse_schedules(self.engine.settings)
        ran: list[str] = []
        now = self.clock()
        for s in schedules:
            if not self.is_due(s, now):
                continue
            self.engine.db.kv_set(self._key(s), str(now))     # saved first: a crash never loops
            result = self.engine.run_scheduled(s.name, s.action, dict(s.params))
            ran.append(s.name)
            self.engine.alerts.add("watch_schedule", None, None,
                                   f"Schedule '{s.name}' {'finished' if result.ok else 'failed'}")
        return ran

    def start(self) -> None:
        if self._thread or not parse_schedules(self.engine.settings)[0]:
            return
        self._thread = threading.Thread(target=self._loop, name="schedules", daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        while not self._stop.wait(self.tick):
            try:
                self.run_due()
            except Exception:
                log.exception("schedule tick failed")

    def stop(self) -> None:
        self._stop.set()
