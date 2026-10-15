"""Optional push notifications (ntfy topic or a generic webhook).

Off by default. The message is deliberately tiny and secret-free: event,
battery percent and time. Delivery problems never reach the caller, and the
target (URL / topic) is never written to a log in full.
"""
from __future__ import annotations

import json
import logging
import os
import re
import urllib.error
import urllib.request
from typing import Callable
from urllib.parse import urlsplit

log = logging.getLogger("cortex.notify")

NTFY_BASE = "https://ntfy.sh/"
_TOPIC_RE = re.compile(r"^[A-Za-z0-9_-]{6,64}$")
TIMEOUT = 5.0
ENV_TARGET = "CORTEX_NOTIFY_TARGET"


def mask_target(kind: str, target: str) -> str:
    """Safe-to-log form: the webhook host only, or the first 2 chars of a topic."""
    if kind == "webhook":
        try:
            return (urlsplit(target).hostname or "?") + "/***"
        except ValueError:
            return "?"
    return (target[:2] + "***") if target else "?"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):  # a redirect could bounce us to anywhere
        return None


def _default_send(req: urllib.request.Request) -> None:
    opener = urllib.request.build_opener(_NoRedirect)
    with opener.open(req, timeout=TIMEOUT) as resp:
        resp.read(256)


def validate_target(kind: str, target: str) -> str | None:
    """Return a problem description (never containing the target), or None."""
    if kind == "ntfy":
        return None if _TOPIC_RE.match(target or "") else "ntfy topic must be 6-64 letters/digits/_/-"
    if kind == "webhook":
        try:
            parts = urlsplit(target)
            ok = (parts.scheme == "https" and parts.hostname and not parts.username
                  and not parts.password and parts.port in (None, 443)
                  and target.isascii() and not any(c.isspace() for c in target))
        except ValueError:
            ok = False
        return None if ok else "webhook must be a plain https URL"
    return "unknown notifier type"


class Notifier:
    def __init__(self, kind: str, target: str,
                 send: Callable[[urllib.request.Request], None] = _default_send):
        self.kind, self.target, self._send = kind, target, send

    @classmethod
    def from_settings(cls, settings, env: dict | None = None,
                      send=_default_send) -> "Notifier | None":
        env = os.environ if env is None else env
        kind = (settings.notifier_type or "").strip().lower()
        target = (env.get(ENV_TARGET) or settings.notifier_target or "").strip()
        if not kind or not target:
            return None
        problem = validate_target(kind, target)
        if problem:
            log.warning("notifier disabled: %s", problem)
            return None
        return cls(kind, target, send)

    def notify(self, event: str, battery_percent: int | None, when: str) -> bool:
        """Best effort. Returns True when the request was accepted."""
        pct = "n/a" if battery_percent is None else f"{int(battery_percent)}%"
        text = f"Cortex One: {event}, battery {pct}, {when}"
        try:
            if self.kind == "ntfy":
                req = urllib.request.Request(
                    NTFY_BASE + self.target, data=text.encode("utf-8"), method="POST",
                    headers={"Title": "Cortex One", "Content-Type": "text/plain; charset=utf-8"})
            else:
                body = json.dumps({"event": event, "battery_percent": battery_percent,
                                   "time": when, "text": text}).encode("utf-8")
                req = urllib.request.Request(
                    self.target, data=body, method="POST",
                    headers={"Content-Type": "application/json"})
            self._send(req)
            return True
        except Exception as exc:  # network down, 4xx/5xx, bad TLS ...: never fatal
            log.warning("notifier %s failed (%s)", mask_target(self.kind, self.target),
                        type(exc).__name__)
            return False
