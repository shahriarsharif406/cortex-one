"""Power-cut / battery watcher for load-shedding.

A small thread checks the battery every ``power_check_seconds`` using psutil
only. On a change (AC lost / restored, crossing the warn or critical level) it
writes an audit entry and an alert row (``GET /alerts``), optionally pushes a
short message, and at critical charge on battery may run ONE configured
precaution (``critical_action``: none, hibernate or lock; never shutdown).
Desktop PCs have no battery: the watcher then does nothing.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

from .db import Database

log = logging.getLogger("cortex.power")

MAX_ALERTS = 200
NOTIFY_COOLDOWN = 120.0          # seconds between pushes of the same kind
HYSTERESIS = 5                   # percent a battery must recover before re-alerting


@dataclass(frozen=True)
class Battery:
    percent: float
    plugged: bool | None         # None = the OS does not know


def psutil_battery() -> Battery | None:
    """Current battery, or None on a desktop / when psutil cannot tell."""
    try:
        import psutil

        b = psutil.sensors_battery()
    except Exception:
        return None
    if b is None or not isinstance(b.percent, (int, float)) or not 0 <= b.percent <= 100:
        return None
    plugged = b.power_plugged if isinstance(b.power_plugged, bool) else None
    return Battery(float(b.percent), plugged)


def _num(value: Any, default: int, lo: int, hi: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return max(lo, min(value, hi))


def critical_threshold(settings) -> int:
    return _num(settings.power_critical_percent, 10, 1, 50)


def warn_threshold(settings) -> int:
    return _num(settings.power_warn_percent, 30, critical_threshold(settings) + 1, 90)


def check_interval(settings) -> int:
    return _num(settings.power_check_seconds, 30, 5, 3600)


class AlertStore:
    def __init__(self, db: Database, now: Callable[[], float] = time.time):
        self.db, self.now = db, now

    def add(self, kind: str, battery_percent: float | None, plugged: bool | None,
            message: str) -> None:
        with self.db.conn() as c:
            c.execute(
                "INSERT INTO alerts (ts, kind, battery_percent, plugged, message)"
                " VALUES (?, ?, ?, ?, ?)",
                (self.now(), kind,
                 None if battery_percent is None else round(battery_percent),
                 None if plugged is None else int(plugged), message[:200]))
            c.execute("DELETE FROM alerts WHERE id <= (SELECT MAX(id) FROM alerts) - ?",
                      (MAX_ALERTS,))

    def recent(self, limit: int = 20) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 100))
        with self.db.conn() as c:
            rows = c.execute(
                "SELECT id, ts, kind, battery_percent, plugged, message FROM alerts"
                " ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["plugged"] = None if d["plugged"] is None else bool(d["plugged"])
            out.append(d)
        return out


class PowerWatcher:
    """One ``tick()`` = one check. ``run_forever`` just calls it on a timer."""

    def __init__(self, engine, provider: Callable[[], Battery | None] = psutil_battery,
                 notifier=None, clock: Callable[[], float] = time.monotonic):
        self.engine, self.provider, self.notifier, self.clock = engine, provider, notifier, clock
        self.stop = threading.Event()
        self._plugged: bool | None = None
        self._level = "ok"                      # ok | warn | critical
        self._last_notified: dict[str, float] = {}
        self._warned_no_battery = False

    # -- one check ----------------------------------------------------------
    def tick(self) -> list[str]:
        """Returns the event kinds recorded during this check."""
        try:
            battery = self.provider()
        except Exception:
            battery = None
        if battery is None:
            if not self._warned_no_battery:
                self._warned_no_battery = True
                log.info("no battery detected; power watcher is idle")
            return []
        s = self.engine.settings
        warn, crit = warn_threshold(s), critical_threshold(s)
        events: list[str] = []

        if self._plugged is not None and battery.plugged is not None:
            if self._plugged and not battery.plugged:
                events.append("ac_lost")
            elif not self._plugged and battery.plugged:
                events.append("ac_restored")
        if battery.plugged is not None:
            self._plugged = battery.plugged

        on_battery = battery.plugged is False
        pct = battery.percent
        if battery.plugged is True or pct > warn + HYSTERESIS:
            self._level = "ok"                  # recovered: allow future alerts
        elif on_battery:
            if pct <= crit and self._level != "critical":
                self._level = "critical"
                events.append("battery_critical")
            elif crit < pct <= warn and self._level == "ok":
                self._level = "warn"
                events.append("battery_warn")
            elif pct > crit + HYSTERESIS and self._level == "critical":
                self._level = "warn"            # charged a bit while still unplugged

        for kind in events:
            self._record(kind, battery)
        if "battery_critical" in events:
            self._critical_action(battery)
        return events

    # -- helpers ------------------------------------------------------------
    TEXT = {
        "ac_lost": "Power cut: running on battery",
        "ac_restored": "Power is back: charging",
        "battery_warn": "Battery low",
        "battery_critical": "Battery critical",
    }

    def _record(self, kind: str, battery: Battery) -> None:
        pct = round(battery.percent)
        message = f"{self.TEXT[kind]} ({pct}%)"
        self.engine.alerts.add(kind, battery.percent, battery.plugged, message)
        self.engine.audit.log("watcher", "power", kind,
                              {"battery_percent": pct, "plugged": battery.plugged},
                              "ok", message)
        if self.notifier is None:
            return
        now = self.clock()
        last = self._last_notified.get(kind)
        if last is not None and now - last < NOTIFY_COOLDOWN:
            return                              # flapping power: don't spam the phone
        self._last_notified[kind] = now
        try:
            self.notifier.notify(self.TEXT[kind], pct, time.strftime("%H:%M"))
        except Exception:                       # a notifier must never hurt the agent
            log.warning("notifier raised %s", "error")

    def _critical_action(self, battery: Battery) -> None:
        try:
            result = self.engine.run_power_action(battery.percent, battery.plugged)
        except Exception as exc:
            log.warning("critical action failed (%s)", type(exc).__name__)
            return
        if result is not None:
            self.engine.alerts.add("critical_action", battery.percent, battery.plugged,
                                   f"{self.engine.settings.critical_action}: "
                                   f"{'done' if result.ok else 'failed'}")

    # -- thread -------------------------------------------------------------
    def run_forever(self) -> None:
        interval = check_interval(self.engine.settings)
        while not self.stop.wait(interval):
            try:
                self.tick()
            except Exception as exc:            # keep watching no matter what
                log.warning("power check failed (%s)", type(exc).__name__)

    def start(self) -> threading.Thread:
        t = threading.Thread(target=self.run_forever, name="power-watch", daemon=True)
        t.start()
        return t
