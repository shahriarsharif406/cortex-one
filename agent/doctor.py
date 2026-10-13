"""`doctor`: a health check of the setup, in plain Bangla / English lines.

It never prints secrets. The API key is reported only as set / not set.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from .config import Settings

OK, WARN, FAIL = "OK", "WARN", "FAIL"


@dataclass
class Check:
    level: str
    bn: str
    en: str

    def line(self) -> str:
        return f"[{self.level:<4}] {self.bn} / {self.en}"


def _port_free(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind((host, port))
        except OSError:
            return False
    return True


def _app_exists(cmd: list[str]) -> bool:
    if not cmd:
        return False
    exe = cmd[0]
    return Path(exe).exists() if os.path.isabs(exe) else shutil.which(exe) is not None


def run_checks(settings: Settings, env: Mapping[str, str] | None = None,
               version: tuple[int, int] | None = None) -> list[Check]:
    env = os.environ if env is None else env
    v = version or sys.version_info[:2]
    out: list[Check] = []

    # Python
    if v >= (3, 10):
        out.append(Check(OK, f"Python {v[0]}.{v[1]} ঠিক আছে", f"Python {v[0]}.{v[1]} is fine"))
    else:
        out.append(Check(FAIL, f"Python {v[0]}.{v[1]} পুরনো, ৩.১০+ লাগবে",
                         f"Python {v[0]}.{v[1]} is too old, need 3.10+"))

    # data dir writable
    try:
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        probe = settings.data_dir / ".doctor-probe"
        probe.write_text("x", encoding="utf-8")
        probe.unlink()
        out.append(Check(OK, "ডেটা ফোল্ডারে লেখা যায়", f"data folder writable: {settings.data_dir}"))
    except OSError as exc:
        out.append(Check(FAIL, "ডেটা ফোল্ডারে লেখা যাচ্ছে না",
                         f"data folder not writable: {type(exc).__name__}"))

    # config valid
    cfg = settings.config_path
    if not cfg.exists():
        out.append(Check(WARN, "config.json নেই; ডিফল্ট ব্যবহার হচ্ছে (init-config চালান)",
                         "no config.json yet; using defaults (run init-config)"))
    else:
        try:
            raw = json.loads(cfg.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("not an object")
            problems = []
            if not isinstance(settings.port, int) or not 1 <= settings.port <= 65535:
                problems.append("port")
            for name in ("allowed_apps", "approved_scripts", "allowed_logs"):
                if not isinstance(getattr(settings, name), dict):
                    problems.append(name)
            for name in ("allowed_domains", "watched_programs"):
                if not isinstance(getattr(settings, name), list):
                    problems.append(name)
            if problems:
                out.append(Check(FAIL, f"config.json-এ ভুল: {', '.join(problems)}",
                                 f"config.json invalid fields: {', '.join(problems)}"))
            else:
                out.append(Check(OK, "config.json ঠিক আছে", "config.json is valid"))
        except (ValueError, OSError) as exc:
            out.append(Check(FAIL, "config.json পড়া যায়নি",
                             f"config.json unreadable ({type(exc).__name__})"))

    # host / port
    if settings.host == "0.0.0.0":
        out.append(Check(FAIL, "host 0.0.0.0 বিপজ্জনক; Tailscale IP দিন",
                         "host is 0.0.0.0, which exposes every network; use the Tailscale IP"))
    else:
        out.append(Check(OK, f"host {settings.host} নিরাপদ", f"host {settings.host} is not 0.0.0.0"))
    if _port_free(settings.host, settings.port):
        out.append(Check(OK, f"পোর্ট {settings.port} ফাঁকা", f"port {settings.port} is free"))
    else:
        out.append(Check(WARN, f"পোর্ট {settings.port} ব্যস্ত (এজেন্ট হয়তো চালু আছে)",
                         f"port {settings.port} is in use (agent may already be running)"))

    # AI key: only whether it is set
    if env.get("ANTHROPIC_API_KEY", "").strip():
        out.append(Check(OK, "ANTHROPIC_API_KEY সেট আছে", "ANTHROPIC_API_KEY is set"))
    else:
        out.append(Check(WARN, "ANTHROPIC_API_KEY সেট নেই; AI বন্ধ", "ANTHROPIC_API_KEY not set; AI is off"))

    # roots
    if not settings.allowed_roots:
        out.append(Check(WARN, "allowed_roots খালি; ফাইল অ্যাকশন বন্ধ", "allowed_roots empty; file actions are off"))
    for root in settings.allowed_roots:
        if Path(root).expanduser().is_dir():
            out.append(Check(OK, f"ফোল্ডার আছে: {root}", f"allowed root exists: {root}"))
        else:
            out.append(Check(WARN, f"ফোল্ডার নেই: {root}", f"allowed root missing: {root}"))

    # apps
    for name, cmd in settings.allowed_apps.items():
        if _app_exists(list(cmd)):
            out.append(Check(OK, f"অ্যাপ পাওয়া গেছে: {name}", f"app found: {name}"))
        else:
            out.append(Check(WARN, f"অ্যাপ পাওয়া যায়নি: {name}", f"app not found: {name}"))

    # screenshots folder must sit inside the allowed roots
    from .actions import ActionError, resolve_allowed
    try:
        resolve_allowed(str(settings.screenshots_dir), settings.allowed_roots)
        out.append(Check(OK, "স্ক্রিনশট ফোল্ডার অনুমোদিত এলাকার ভেতরে", "screenshots folder is inside allowed roots"))
    except ActionError:
        out.append(Check(WARN, "স্ক্রিনশট ফোল্ডার allowed_roots-এর বাইরে; screenshot বন্ধ",
                         "screenshots_dir is outside allowed_roots; screenshots are off"))

    # logs allowlist
    for short, path in settings.allowed_logs.items():
        if Path(path).is_file():
            out.append(Check(OK, f"লগ ফাইল আছে: {short}", f"log file exists: {short}"))
        else:
            out.append(Check(WARN, f"লগ ফাইল নেই: {short}", f"log file missing: {short}"))

    # SMS
    if settings.sms_pin_hash and settings.sms_allowed_numbers and settings.gateway_secret_hash:
        out.append(Check(OK, f"SMS চালু ({len(settings.sms_allowed_numbers)}টি নম্বর)",
                         f"SMS is set up ({len(settings.sms_allowed_numbers)} number(s))"))
    else:
        out.append(Check(WARN, "SMS চালু করা হয়নি (sms-setup চালান)", "SMS not set up (run sms-setup)"))
    return out


def format_report(checks: list[Check]) -> str:
    lines = [c.line() for c in checks]
    fails = sum(c.level == FAIL for c in checks)
    warns = sum(c.level == WARN for c in checks)
    lines.append(f"সারাংশ / Summary: {fails} fail, {warns} warn")
    return "\n".join(lines)
