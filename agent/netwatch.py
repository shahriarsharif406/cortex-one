"""Network watchdog: REPORT ONLY.

Every ``net_check_seconds`` it tries a plain TCP connect to a small fixed list of
``host:port`` targets taken from config (defaults: the Tailscale control plane and
api.anthropic.com, both on 443). The state is ``ok`` (all reachable), ``degraded``
(some) or ``offline`` (none). A state change must be seen twice in a row before it
counts, so one lost packet does not raise an alarm. Changes become alerts (kind
``net_*``, shown by ``GET /network``) and, if configured, a short push.

It NEVER changes network adapters, routes, metrics or the firewall. Switching to
the SIM tether is the job of the separate admin task (scripts/network-failover.ps1).
"""
from __future__ import annotations

import logging
import re
import socket
import threading
import time
from typing import Callable

log = logging.getLogger("cortex.net")

DEFAULT_TARGETS = ["controlplane.tailscale.com:443", "api.anthropic.com:443"]
MAX_TARGETS = 6
CONNECT_TIMEOUT = 3.0
_HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")

TEXT = {
    "net_ok": "Internet is back",
    "net_degraded": "Internet is partly reachable",
    "net_offline": "Internet is unreachable from this computer",
}


def parse_targets(raw) -> tuple[list[tuple[str, int]], list[str]]:
    """(valid targets, problems). Invalid entries are dropped, never connected to."""
    if raw is None or raw == []:
        raw = DEFAULT_TARGETS
    problems: list[str] = []
    if not isinstance(raw, list):
        return [], ["net_watch_targets must be a list of \"host:port\" texts"]
    out: list[tuple[str, int]] = []
    for item in raw[:MAX_TARGETS]:
        if not isinstance(item, str) or item.count(":") != 1:
            problems.append("a target must look like host:port")
            continue
        host, port = item.strip().split(":")
        if not (host.isascii() and _HOST_RE.fullmatch(host)) or ".." in host:
            problems.append("a target has an invalid host name")
            continue
        if not (port.isascii() and port.isdigit() and 1 <= int(port) <= 65535):
            problems.append("a target has an invalid port")
            continue
        out.append((host.lower(), int(port)))
    if len(raw) > MAX_TARGETS:
        problems.append(f"only the first {MAX_TARGETS} targets are used")
    return out, problems


def tcp_probe(host: str, port: int, timeout: float = CONNECT_TIMEOUT) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


class NetWatcher:
    def __init__(self, engine, probe: Callable[[str, int], bool] = tcp_probe,
                 notifier=None, clock: Callable[[], float] = time.time):
        self.engine, self.probe, self.notifier, self.clock = engine, probe, notifier, clock
        self.stop = threading.Event()
        self.state = "unknown"           # unknown | ok | degraded | offline
        self.since: float | None = None
        self.last_check: float | None = None
        self._candidate: str | None = None
        self.targets, self.problems = parse_targets(
            getattr(engine.settings, "net_watch_targets", None))

    @staticmethod
    def classify(results: list[bool]) -> str:
        if not results:
            return "unknown"
        up = sum(results)
        return "ok" if up == len(results) else "offline" if up == 0 else "degraded"

    def tick(self) -> str | None:
        """One check. Returns the new state when it changed, else None."""
        results = []
        for host, port in self.targets:
            try:
                results.append(bool(self.probe(host, port)))
            except Exception:
                results.append(False)
        seen = self.classify(results)
        self.last_check = self.clock()
        if seen == "unknown" or seen == self.state:
            self._candidate = None
            return None
        first = self.state == "unknown"
        if not first and self._candidate != seen:
            self._candidate = seen           # wait for a second identical reading
            return None
        self._candidate = None
        previous, self.state, self.since = self.state, seen, self.clock()
        if first and seen == "ok":
            return seen                      # normal start: nothing to report
        self._record("net_" + seen, previous)
        return seen

    def _record(self, kind: str, previous: str) -> None:
        message = TEXT[kind]
        self.engine.alerts.add(kind, None, None, message)
        self.engine.audit.log("watcher", "net", kind, {"from": previous}, "ok", message)
        if self.notifier is not None:
            try:
                self.notifier.notify(message, None, time.strftime("%H:%M"))
            except Exception:
                log.warning("notifier raised %s", "error")

    def snapshot(self) -> dict:
        return {"state": self.state, "since": self.since, "last_check": self.last_check,
                "targets": [f"{h}:{p}" for h, p in self.targets],
                "alerts": self.engine.alerts.recent(20, scope="net")}

    def run_forever(self) -> None:
        interval = _interval(self.engine.settings)
        while not self.stop.is_set():
            try:
                self.tick()
            except Exception as exc:
                log.warning("network check failed (%s)", type(exc).__name__)
            if self.stop.wait(interval):
                return

    def start(self) -> threading.Thread:
        t = threading.Thread(target=self.run_forever, name="net-watch", daemon=True)
        t.start()
        return t


def _interval(settings) -> int:
    v = getattr(settings, "net_check_seconds", 30)
    if isinstance(v, bool) or not isinstance(v, int):
        return 30
    return max(10, min(v, 3600))
