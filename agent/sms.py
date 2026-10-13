"""Offline fallback: control the laptop by SMS (e.g. ``SHUTDOWN 4821``).

An old Android phone with a SIM acts as the SMS gateway and forwards each
incoming SMS to ``POST /sms/inbound``. Safety layers: sender must be on the
allowlist, the PIN must match (salted hash), repeated wrong PINs lock the
sender out, and only a small set of low-blast-radius commands exist.
"""
from __future__ import annotations

import re
from typing import Callable

from .engine import Engine
from .security import LockoutTracker, verify_secret

COMMANDS = {
    "STATUS": "status",
    "LOCK": "lock",
    "SHUTDOWN": "shutdown",
    "RESTART": "restart",
    "CANCEL": "cancel_shutdown",
    "STOP": "emergency_stop",
}

_BANGLA_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def normalize_number(raw: str) -> str:
    """Normalise to +E.164. Assumes Bangladesh when there is no country code."""
    digits = re.sub(r"[^\d+]", "", raw or "")
    if digits.startswith("+"):
        return digits
    if digits.startswith("00"):
        return "+" + digits[2:]
    if digits.startswith("880"):
        return "+" + digits
    if digits.startswith("0"):
        return "+88" + digits
    return "+" + digits if digits else ""


def parse_sms(text: str) -> tuple[str, str] | None:
    """Return (COMMAND, pin) or None. Accepts Bangla digits and any case."""
    parts = (text or "").translate(_BANGLA_DIGITS).split()
    if len(parts) != 2:
        return None
    command, pin = parts[0].upper(), parts[1]
    if command not in COMMANDS or not pin.isdigit() or not 4 <= len(pin) <= 12:
        return None
    return command, pin


def _mask(number: str) -> str:
    return f"sms:***{number[-4:]}" if len(number) >= 4 else "sms:***"


class SmsHandler:
    def __init__(self, engine: Engine,
                 lockout_now: Callable[[], float] | None = None):
        self.engine = engine
        s = engine.settings
        kwargs = {"now": lockout_now} if lockout_now else {}
        self.lockout = LockoutTracker(s.sms_max_failures, s.sms_lockout_seconds,
                                      **kwargs)

    def handle(self, sender: str, text: str) -> str | None:
        """Process one SMS. Returns a short reply, or None to stay silent."""
        s = self.engine.settings
        number = normalize_number(sender)
        actor = _mask(number)
        allowed = {normalize_number(n) for n in s.sms_allowed_numbers}

        if not s.sms_pin_hash or number not in allowed:
            # Unknown sender or SMS disabled: log, never reply (no oracle).
            self.engine.audit.log(actor, "sms", "-", {}, "rejected", "sender not allowed")
            return None
        if self.lockout.is_locked(number):
            self.engine.audit.log(actor, "sms", "-", {}, "rejected", "locked out")
            return None

        parsed = parse_sms(text)
        if parsed is None:
            self.engine.audit.log(actor, "sms", "-", {}, "rejected", "bad format")
            return "Format: COMMAND PIN. Commands: " + ", ".join(COMMANDS)
        command, pin = parsed
        if not verify_secret(pin, s.sms_pin_hash):
            self.lockout.record_failure(number)
            self.engine.audit.log(actor, "sms", COMMANDS[command], {}, "rejected",
                                  "wrong pin")
            return "Wrong PIN."
        self.lockout.reset(number)

        result = self.engine.run(COMMANDS[command], {}, actor=actor, via="sms")
        return _short_reply(command, result.message, result.data)


def _short_reply(command: str, message: str, data: dict) -> str:
    if command == "STATUS" and data:
        bits = []
        if "battery_percent" in data:
            plug = "plugged" if data.get("plugged_in") else "battery"
            bits.append(f"Batt {data['battery_percent']}% ({plug})")
        if "cpu_percent" in data:
            bits.append(f"CPU {data['cpu_percent']}%")
        if "ram_percent" in data:
            bits.append(f"RAM {data['ram_percent']}%")
        return (" ".join(bits) or "Laptop is on.")[:160]
    return message[:160]
