"""Append-only audit log. Secrets are redacted before they reach disk."""
from __future__ import annotations

import json
import time
from typing import Any, Callable

from .db import Database

MAX_ROWS = 50_000        # the trail is a rolling window, never unbounded disk use
PRUNE_EVERY = 200
MAX_PARAMS_JSON = 2000

SECRET_KEYS = {"token", "pin", "password", "secret", "confirm_token", "code"}


def redact(params: dict[str, Any]) -> dict[str, Any]:
    """Secret-named keys are masked; string values also pass through the log scrubber
    (API keys, bearer tokens, 'pin: 1234' style text), whatever their key is called."""
    from .logging_setup import scrub

    out: dict[str, Any] = {}
    for key, value in params.items():
        if key.lower() in SECRET_KEYS:
            out[key] = "***"
        elif isinstance(value, str):
            value = scrub(value)
            out[key] = value[:200] + "..." if len(value) > 200 else value
        else:
            out[key] = value
    return out


def _scrub(text: str) -> str:
    from .logging_setup import scrub

    return scrub(text)


class AuditLog:
    def __init__(self, db: Database, now: Callable[[], float] = time.time):
        self.db = db
        self.now = now
        self._count = 0

    def log(
        self,
        actor: str,
        via: str,
        action: str,
        params: dict[str, Any],
        status: str,
        detail: str = "",
    ) -> None:
        with self.db.conn() as c:
            c.execute(
                "INSERT INTO audit_log (ts, actor, via, action, params, status, detail)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    self.now(),
                    actor,
                    via,
                    action,
                    json.dumps(redact(params), ensure_ascii=False, default=str)[:MAX_PARAMS_JSON],
                    status,
                    _scrub(detail)[:500],
                ),
            )
            self._count += 1
            if self._count % PRUNE_EVERY == 0:
                c.execute("DELETE FROM audit_log WHERE id <= (SELECT MAX(id) FROM audit_log) - ?",
                          (MAX_ROWS,))

    def recent(self, limit: int = 50) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 500))
        with self.db.conn() as c:
            rows = c.execute(
                "SELECT ts, actor, via, action, params, status, detail"
                " FROM audit_log ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [dict(r) for r in rows]


def export_csv(db: Database, path, days: int = 7, now: float | None = None) -> int:
    """Write the last ``days`` days of the audit trail as CSV. Returns the row count.

    Cells are re-scrubbed (tokens / keys / PINs) and neutralised against
    spreadsheet formula injection (a leading = + - @ gets a quote).
    """
    import csv

    from .logging_setup import scrub

    days = max(1, min(int(days), 3650))
    since = (time.time() if now is None else now) - days * 86400
    with db.conn() as c:
        rows = c.execute(
            "SELECT ts, actor, via, action, params, status, detail FROM audit_log"
            " WHERE ts >= ? ORDER BY id", (since,)).fetchall()

    def cell(value: object) -> str:
        text = scrub(str(value))
        text = "".join(ch if ch >= " " or ch == "\t" else " " for ch in text)
        return "'" + text if text[:1] in ("=", "+", "-", "@", "\t") else text

    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["time", "actor", "via", "action", "params", "status", "detail"])
        for r in rows:
            when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["ts"]))
            w.writerow([when, cell(r["actor"]), cell(r["via"]), cell(r["action"]),
                        cell(r["params"]), cell(r["status"]), cell(r["detail"])])
    return len(rows)
