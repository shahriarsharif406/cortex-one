"""TOTP (RFC 6238) for the SMS fallback, standard library only.

HMAC-SHA1, 30 second steps, 6 digits: what every authenticator app does.
A code is accepted for the current step and one step either side (clock
drift, SMS delay), and each step can be used only ONCE: the last accepted
step is stored in the database, so replaying a captured SMS fails even after
a restart of the agent.

Storing the shared secret (the tradeoff)
  The secret must be readable again to check codes, so it cannot be hashed
  like the static PIN. On Windows it is encrypted with DPAPI (CryptProtectData,
  current-user scope, through ctypes): the file is useless if copied to another
  PC or user account, but any program running as *you* could still decrypt it.
  On other systems it falls back to a plain file with permissions 600 and says
  so. The secret is shown once on the terminal at setup and is never written to
  a log, the audit trail or config.json.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
import struct
import sys
import time
from pathlib import Path

from .db import Database

STEP_SECONDS = 30
DIGITS = 6
WINDOW = 1                       # accept t-1, t, t+1
SECRET_FILE = "sms_totp.secret"
_ENTROPY = b"cortex-one/sms-totp/v1"
_KV_KEY = "sms_totp_last_step"


# ---------------------------------------------------------------- algorithm
def new_secret() -> str:
    """160 random bits as base32 (what authenticator apps expect)."""
    return base64.b32encode(secrets.token_bytes(20)).decode("ascii")


def _key(secret_b32: str) -> bytes:
    cleaned = secret_b32.replace(" ", "").replace("-", "").upper()
    cleaned += "=" * (-len(cleaned) % 8)
    return base64.b32decode(cleaned, casefold=True)


def hotp(secret_b32: str, counter: int) -> str:
    digest = hmac.new(_key(secret_b32), struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % 10 ** DIGITS).zfill(DIGITS)


def current_step(now: float | None = None) -> int:
    return int((time.time() if now is None else now) // STEP_SECONDS)


def totp(secret_b32: str, now: float | None = None) -> str:
    return hotp(secret_b32, current_step(now))


def match_step(secret_b32: str, code: str, now: float | None = None) -> int | None:
    """The time step ``code`` belongs to (within the window), or None.
    Every candidate is compared in constant time."""
    if not (isinstance(code, str) and code.isascii() and code.isdigit() and len(code) == DIGITS):
        return None
    t = current_step(now)
    found = None
    for step in range(t - WINDOW, t + WINDOW + 1):
        if hmac.compare_digest(hotp(secret_b32, step), code):
            found = step
    return found


class ReplayGuard:
    """Remembers the newest accepted step; an equal or older step is refused."""

    def __init__(self, db: Database):
        self.db = db

    def claim(self, step: int) -> bool:
        """Atomically record ``step``. False if it (or a later one) was used."""
        with self.db.conn() as c:
            cur = c.execute(
                "INSERT INTO kv (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value "
                "WHERE CAST(kv.value AS INTEGER) < CAST(excluded.value AS INTEGER)",
                (_KV_KEY, str(int(step))))
            return cur.rowcount == 1


def verify_and_claim(secret_b32: str, code: str, guard: ReplayGuard,
                     now: float | None = None) -> bool:
    step = match_step(secret_b32, code, now)
    return step is not None and guard.claim(step)


# ------------------------------------------------------------ secret storage
# ctypes is imported inside so this module loads on any OS.
def _dpapi(data: bytes, protect: bool) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    def blob(b: bytes) -> tuple[DATA_BLOB, object]:
        buf = ctypes.create_string_buffer(b, len(b))
        return DATA_BLOB(len(b), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf

    crypt32, kernel32 = ctypes.windll.crypt32, ctypes.windll.kernel32
    src, keep1 = blob(data)
    ent, keep2 = blob(_ENTROPY)
    out = DATA_BLOB()
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    args = (ctypes.byref(src), None, ctypes.byref(ent), None, None, 0x01, ctypes.byref(out))
    if not fn(*args):                       # 0x01 = CRYPTPROTECT_UI_FORBIDDEN
        raise OSError("DPAPI call failed")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        kernel32.LocalFree(out.pbData)
        del keep1, keep2


def _on_windows() -> bool:
    return sys.platform == "win32"


def secret_path(data_dir: Path) -> Path:
    return Path(data_dir) / SECRET_FILE


def save_secret(data_dir: Path, secret_b32: str) -> str:
    """Store the secret. Returns 'dpapi' or 'plain-600' (a weaker fallback)."""
    path = secret_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = secret_b32.encode("ascii")
    if _on_windows():
        path.write_bytes(b"DPAPI1:" + _dpapi(raw, True))
        return "dpapi"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(b"PLAIN1:" + raw)
    os.chmod(path, 0o600)
    return "plain-600"


def load_secret(data_dir: Path) -> str | None:
    path = secret_path(data_dir)
    try:
        data = path.read_bytes()
    except OSError:
        return None
    try:
        if data.startswith(b"DPAPI1:") and _on_windows():
            return _dpapi(data[7:], False).decode("ascii")
        if data.startswith(b"PLAIN1:"):
            return data[7:].decode("ascii")
    except (OSError, UnicodeDecodeError):
        return None
    return None


def delete_secret(data_dir: Path) -> None:
    try:
        secret_path(data_dir).unlink()
    except OSError:
        pass
