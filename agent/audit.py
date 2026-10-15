"""Append-only audit log. Secrets are redacted before they reach disk."""
from __future__ import annotations

import json
import time
from typing import Any, Callable

from .db import Database

SECRET_KEYS = {"token", "pin", "password", "secret", "confirm_token", "code"}


def redact(params: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in params.items():
        if key.lower() in SECRET_KEYS:
            out[key] = "***"
        elif isinstance(value, str) and len(value) > 200:
            out[key] = value[:200] + "..."
        else:
            out[key] = value
    return out


class AuditLog:
    def __init__(self, db: Database, now: Callable[[], float] = time.time):
        self.db = db
        self.now = now

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
                    json.dumps(redact(params), ensure_ascii=False),
                    status,
                    detail[:500],
                ),
            )

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
