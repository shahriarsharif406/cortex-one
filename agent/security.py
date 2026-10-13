"""Pairing, device tokens, rate limiting, lockout and confirmations.

Design rules
- Device tokens are 256-bit random values; only their SHA-256 is stored.
- Pairing codes are 6 digits, single use, short lived, and guarded by a
  global lockout so they cannot be brute-forced.
- Low-entropy secrets (the SMS PIN) are stored with PBKDF2 + salt.
- All secret comparisons are constant time.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import threading
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Any, Callable

from .config import Settings
from .db import Database


# ---------------------------------------------------------------- hashing
def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def hash_secret(secret: str, iterations: int = 200_000) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", secret.encode("utf-8"), bytes.fromhex(salt), iterations
    ).hex()
    return f"pbkdf2${iterations}${salt}${digest}"


def verify_secret(secret: str, stored: str) -> bool:
    try:
        scheme, iterations, salt, digest = stored.split("$")
        if scheme != "pbkdf2":
            return False
        candidate = hashlib.pbkdf2_hmac(
            "sha256", secret.encode("utf-8"), bytes.fromhex(salt), int(iterations)
        ).hex()
    except (ValueError, AttributeError):
        return False
    return hmac.compare_digest(candidate, digest)


# ------------------------------------------------------------ rate limits
class RateLimiter:
    """Sliding-window limiter, ``limit`` calls per ``window`` seconds per key."""

    def __init__(self, limit: int, window: float = 60.0,
                 now: Callable[[], float] = time.monotonic):
        self.limit, self.window, self.now = limit, window, now
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        t = self.now()
        with self._lock:
            hits = self._hits[key]
            while hits and t - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(t)
            return True


class LockoutTracker:
    """Locks a key for ``lockout_seconds`` after ``max_failures`` failures."""

    def __init__(self, max_failures: int, lockout_seconds: float,
                 now: Callable[[], float] = time.monotonic):
        self.max_failures, self.lockout_seconds, self.now = (
            max_failures, lockout_seconds, now)
        self._failures: dict[str, int] = defaultdict(int)
        self._locked_until: dict[str, float] = {}
        self._lock = threading.Lock()

    def is_locked(self, key: str) -> bool:
        with self._lock:
            until = self._locked_until.get(key)
            if until is None:
                return False
            if self.now() >= until:
                del self._locked_until[key]
                self._failures[key] = 0
                return False
            return True

    def record_failure(self, key: str) -> None:
        with self._lock:
            self._failures[key] += 1
            if self._failures[key] >= self.max_failures:
                self._locked_until[key] = self.now() + self.lockout_seconds

    def reset(self, key: str) -> None:
        with self._lock:
            self._failures[key] = 0
            self._locked_until.pop(key, None)


# ----------------------------------------------------------------- pairing
@dataclass(frozen=True)
class Device:
    id: int
    name: str


class PairingLocked(Exception):
    """Too many failed pairing attempts."""


class PairingManager:
    def __init__(self, db: Database, settings: Settings,
                 now: Callable[[], float] = time.time,
                 lockout_now: Callable[[], float] = time.monotonic):
        self.db, self.settings, self.now = db, settings, now
        self.lockout = LockoutTracker(
            settings.max_pair_failures, settings.pair_lockout_seconds, lockout_now)

    def create_code(self) -> str:
        """Create a one-time 6-digit code. Older unused codes are discarded."""
        code = f"{secrets.randbelow(1_000_000):06d}"
        with self.db.conn() as c:
            c.execute("DELETE FROM pairing_codes")
            c.execute(
                "INSERT INTO pairing_codes (code_hash, expires_at) VALUES (?, ?)",
                (sha256_hex(code), self.now() + self.settings.pairing_ttl_seconds),
            )
        return code

    def pair(self, code: str, device_name: str) -> str | None:
        """Exchange a valid code for a device token, or return None."""
        if self.lockout.is_locked("pairing"):
            raise PairingLocked()
        name = (device_name or "").strip()[:60] or "phone"
        ok = False
        with self.db.conn() as c:
            row = c.execute(
                "SELECT code_hash, expires_at, used FROM pairing_codes"
            ).fetchone()
            if (row and not row["used"] and row["expires_at"] >= self.now()
                    and hmac.compare_digest(row["code_hash"], sha256_hex(str(code)))):
                ok = True
                c.execute("UPDATE pairing_codes SET used = 1")
        if not ok:
            self.lockout.record_failure("pairing")
            return None
        self.lockout.reset("pairing")
        token = secrets.token_urlsafe(32)
        with self.db.conn() as c:
            c.execute(
                "INSERT INTO devices (name, token_hash, created_at) VALUES (?, ?, ?)",
                (name, sha256_hex(token), self.now()),
            )
        return token

    def authenticate(self, token: str | None) -> Device | None:
        if not token:
            return None
        with self.db.conn() as c:
            row = c.execute(
                "SELECT id, name FROM devices WHERE token_hash = ? AND revoked = 0",
                (sha256_hex(token),),
            ).fetchone()
            if not row:
                return None
            c.execute("UPDATE devices SET last_seen = ? WHERE id = ?",
                      (self.now(), row["id"]))
        return Device(id=row["id"], name=row["name"])

    def list_devices(self) -> list[dict[str, Any]]:
        with self.db.conn() as c:
            rows = c.execute(
                "SELECT id, name, created_at, last_seen, revoked FROM devices"
                " ORDER BY id").fetchall()
        return [dict(r) for r in rows]

    def revoke(self, device_id: int) -> bool:
        with self.db.conn() as c:
            cur = c.execute("UPDATE devices SET revoked = 1 WHERE id = ?",
                            (device_id,))
            return cur.rowcount > 0


# ------------------------------------------------------------ confirmation
class ConfirmationStore:
    """Two-step confirmation for high-risk actions.

    The first request returns a one-time token bound to (device, action,
    params). Executing needs that token back within ``ttl`` seconds.
    """

    def __init__(self, ttl: float, now: Callable[[], float] = time.monotonic):
        self.ttl, self.now = ttl, now
        # token -> (expires_at, fingerprint, device_id, action, params, source)
        self._pending: dict[str, tuple[float, str, int, str, dict[str, Any], str]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _fingerprint(device_id: int, action: str, params: dict[str, Any]) -> str:
        blob = json.dumps([device_id, action, params], sort_keys=True,
                          ensure_ascii=False)
        return sha256_hex(blob)

    def issue(self, device_id: int, action: str, params: dict[str, Any],
              source: str = "http") -> str:
        token = secrets.token_urlsafe(16)
        with self._lock:
            self._purge()
            self._pending[token] = (
                self.now() + self.ttl, self._fingerprint(device_id, action, params),
                device_id, action, dict(params), source)
        return token

    def consume(self, token: str, device_id: int, action: str,
                params: dict[str, Any]) -> bool:
        with self._lock:
            self._purge()
            entry = self._pending.pop(token, None)
        if entry is None:
            return False
        return hmac.compare_digest(
            entry[1], self._fingerprint(device_id, action, params))

    # -- inspection, so the phone can show exactly what it is confirming ------
    def list_pending(self, device_id: int, source: str) -> list[dict[str, Any]]:
        """Pending requests of one device and source, soonest-expiring first."""
        with self._lock:
            self._purge()
            t = self.now()
            rows = [{"confirm_token": tok, "action": e[3], "params": dict(e[4]),
                     "expires_in": max(0, round(e[0] - t))}
                    for tok, e in self._pending.items() if e[2] == device_id and e[5] == source]
        return sorted(rows, key=lambda r: r["expires_in"])

    def peek(self, token: str, device_id: int, source: str) -> tuple[str, dict[str, Any]] | None:
        """(action, params) of a live pending request owned by this device, else None."""
        with self._lock:
            self._purge()
            e = self._pending.get(token)
        if e is None or e[2] != device_id or e[5] != source:
            return None
        return e[3], dict(e[4])

    def discard(self, token: str, device_id: int, source: str) -> bool:
        with self._lock:
            self._purge()
            e = self._pending.get(token)
            if e is None or e[2] != device_id or e[5] != source:
                return False
            del self._pending[token]
            return True

    def _purge(self) -> None:
        t = self.now()
        for token in [k for k, e in self._pending.items() if e[0] < t]:
            del self._pending[token]
