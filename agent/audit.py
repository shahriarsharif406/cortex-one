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
