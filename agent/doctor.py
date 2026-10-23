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
from typing import Callable, Mapping

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


TASK_NAME = "CortexOneAgent"


def startup_task_state(name: str = TASK_NAME) -> str | None:
    """'ready' | 'disabled' | 'running' | 'missing', or None when it cannot be asked
    (not Windows). Read-only: schtasks /Query with a fixed task name."""
    if sys.platform != "win32":
        return None
    import subprocess

    try:
        proc = subprocess.run(["schtasks", "/Query", "/TN", name, "/FO", "LIST"],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return "missing"
    low = proc.stdout.lower()
    if "disabled" in low:
        return "disabled"
    return "running" if "running" in low else "ready"


def _tailscale_ip(host: str) -> bool:
    parts = host.split(".")
    try:
        a, b = int(parts[0]), int(parts[1])
    except (ValueError, IndexError):
        return False
    return len(parts) == 4 and a == 100 and 64 <= b <= 127


def run_checks(settings: Settings, env: Mapping[str, str] | None = None,
               version: tuple[int, int] | None = None,
               startup_probe: Callable[[], str | None] = startup_task_state,
               battery_probe: Callable[[], object | None] | None = None,
               wake_probe: Callable[[], dict] | None = None,
               adapter_probe: Callable[[], list] | None = None,
               netadapter_probe: Callable[[], list] | None = None,
               show_mac: bool = False) -> list[Check]:
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

    # hosts / port (every configured bind address is validated by agent/netbind.py)
    from .netbind import BindError, classify_address, effective_hosts

    try:
        hosts = effective_hosts(settings)
    except BindError as exc:
        hosts = []
        out.append(Check(FAIL, f"bind ঠিকানা অবৈধ (0.0.0.0 বা পাবলিক নিষিদ্ধ): {exc}",
                         f"invalid bind address(es), 0.0.0.0 / public are never allowed: {exc}"))
    else:
        out.append(Check(OK, f"{len(hosts)}টি bind ঠিকানা বৈধ: {', '.join(hosts)}",
                         f"{len(hosts)} bind address(es) valid: {', '.join(hosts)}"))
    kinds = {h: classify_address(h) for h in hosts}
    if hosts and "tailscale" in kinds.values():
        out.append(Check(OK, "একটি Tailscale IP বাঁধা আছে (ফোন পৌঁছাতে পারবে)",
                         "a Tailscale IP is configured (the phone can reach it)"))
    elif hosts and "lan" in kinds.values():
        out.append(Check(WARN, "শুধু LAN IP আছে; Tailscale IP ছাড়া মোবাইল ডেটা থেকে পৌঁছানো যাবে না",
                         "only a LAN IP: not reachable over mobile data without a Tailscale IP"))
    elif hosts:
        out.append(Check(WARN, "host শুধু এই কম্পিউটার থেকে পৌঁছানো যায়; ফোনের জন্য Tailscale IP দিন",
                         "host is loopback: the phone cannot reach it; set the Tailscale IP"))
    for h in hosts[:1]:
        if _port_free(h, settings.port):
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
        if Path(settings.screenshots_dir).is_dir():
            out.append(Check(OK, "স্ক্রিনশট ফোল্ডার আছে", "screenshots folder exists"))
        else:
            out.append(Check(OK, "স্ক্রিনশট ফোল্ডার এখনো নেই (প্রথম screenshot-এ তৈরি হবে)",
                             "screenshots folder does not exist yet (created on first screenshot)"))
    except ActionError:
        out.append(Check(WARN, "স্ক্রিনশট ফোল্ডার allowed_roots-এর বাইরে; screenshot বন্ধ",
                         "screenshots_dir is outside allowed_roots; screenshots are off"))

    # reports folder (write_report / zip_folder)
    try:
        rep = resolve_allowed(str(settings.reports_dir), settings.allowed_roots)
        shots = Path(settings.screenshots_dir).resolve()
        if rep == shots or shots in rep.parents:
            out.append(Check(WARN, "reports_dir screenshots_dir-এর সঙ্গে মিলে গেছে; রিপোর্ট বন্ধ",
                             "reports_dir overlaps screenshots_dir; reports are off"))
        else:
            out.append(Check(OK, "রিপোর্ট ফোল্ডার অনুমোদিত এলাকার ভেতরে",
                             "reports folder is inside allowed roots"))
    except ActionError:
        out.append(Check(WARN, "রিপোর্ট ফোল্ডার allowed_roots-এর বাইরে; রিপোর্ট/zip বন্ধ",
                         "reports_dir is outside allowed_roots; write_report and zip_folder are off"))

    # logs allowlist
    for short, path in settings.allowed_logs.items():
        if Path(path).is_file():
            out.append(Check(OK, f"লগ ফাইল আছে: {short}", f"log file exists: {short}"))
        else:
            out.append(Check(WARN, f"লগ ফাইল নেই: {short}", f"log file missing: {short}"))

    # SMS (never prints PINs, secrets or numbers)
    from . import totp

    gateway = bool(settings.gateway_secret_hash and settings.sms_allowed_numbers)
    if settings.sms_mode == "totp":
        have_secret = totp.load_secret(settings.data_dir) is not None
        if have_secret and gateway:
            out.append(Check(OK, "SMS চালু, TOTP কোড মোড (replay সুরক্ষিত)",
                             "SMS is set up with TOTP codes (replay protected)"))
            out.append(Check(OK, "TOTP সিক্রেট কনফিগার করা আছে", "TOTP secret is configured"))
        else:
            out.append(Check(WARN, "TOTP মোড বাছা কিন্তু সিক্রেট/গেটওয়ে নেই (sms-setup --totp চালান)",
                             "TOTP mode selected but secret/gateway missing (run sms-setup --totp)"))
    elif settings.sms_pin_hash and gateway:
        out.append(Check(WARN, f"SMS চালু ({len(settings.sms_allowed_numbers)}টি নম্বর) কিন্তু স্থির পিন: replay সুরক্ষা নেই; TOTP ভালো",
                         f"SMS is set up ({len(settings.sms_allowed_numbers)} number(s)) with a static PIN: no replay protection; TOTP is better"))
        out.append(Check(WARN, "TOTP কনফিগার করা নেই", "TOTP is not configured"))
    else:
        out.append(Check(WARN, "SMS চালু করা হয়নি (sms-setup চালান)", "SMS not set up (run sms-setup)"))

    # startup task
    state = startup_probe()
    if state is None:
        out.append(Check(WARN, "অটো-স্টার্ট টাস্ক যাচাই করা যায়নি (Windows নয়)",
                         "startup task could not be checked (not Windows)"))
    elif state == "missing":
        out.append(Check(WARN, "অটো-স্টার্ট টাস্ক ইনস্টল করা নেই (install-startup.ps1)",
                         "startup task not installed (install-startup.ps1)"))
    elif state == "disabled":
        out.append(Check(WARN, "অটো-স্টার্ট টাস্ক বন্ধ করা আছে", "startup task is disabled"))
    else:
        out.append(Check(OK, f"অটো-স্টার্ট টাস্ক আছে ({state})", f"startup task is installed ({state})"))

    # power watcher, battery, notifier (presence only, never the value)
    from .notify import Notifier, validate_target
    from .power import psutil_battery

    battery = (battery_probe or psutil_battery)()
    if battery is not None:
        out.append(Check(OK, "ব্যাটারি পাওয়া গেছে (কারেন্ট-কাট সতর্কতা কাজ করবে)",
                         "battery detected (power-cut alerts will work)"))
    else:
        out.append(Check(WARN, "ব্যাটারি পাওয়া যায়নি (ডেস্কটপ?); পাওয়ার ওয়াচার নিষ্ক্রিয় থাকবে",
                         "no battery detected (desktop?); the power watcher stays idle"))
    action = settings.critical_action
    if action not in ("none", "hibernate", "lock"):
        out.append(Check(WARN, "critical_action অবৈধ; কিছুই করা হবে না (none/hibernate/lock)",
                         "critical_action is invalid; nothing will be done (none/hibernate/lock)"))
    elif action != "none":
        out.append(Check(OK, f"critical_action = {action} (shutdown কখনো নয়)",
                         f"critical_action = {action} (never shutdown)"))
    kind = (settings.notifier_type or "").strip().lower()
    target = (env.get("CORTEX_NOTIFY_TARGET") or settings.notifier_target or "").strip()
    if not kind:
        out.append(Check(OK, "পুশ নোটিফায়ার বন্ধ (ডিফল্ট)", "push notifier is off (default)"))
    elif not target:
        out.append(Check(WARN, "নোটিফায়ার ধরন দেওয়া আছে কিন্তু টার্গেট নেই",
                         "notifier type is set but no target is configured"))
    elif validate_target(kind, target):
        out.append(Check(WARN, "নোটিফায়ার টার্গেট অবৈধ; বন্ধ থাকবে", "notifier target is invalid; it stays off"))
    else:
        out.append(Check(OK, f"পুশ নোটিফায়ার কনফিগার করা আছে ({kind})", f"push notifier is configured ({kind})"))

    # watch rules (names only; a rejected rule is never evaluated)
    from .watch import parse_rules

    rules, problems = parse_rules(settings)
    if not settings.watch_rules and not problems:
        out.append(Check(OK, "watch_rules নেই (কোডিং এজেন্ট ওয়াচার বন্ধ)",
                         "no watch_rules (coding-agent watcher is off)"))
    else:
        for prob in problems:
            out.append(Check(WARN, f"watch_rules সমস্যা: {prob}", f"watch_rules problem: {prob}"))
        if rules:
            out.append(Check(OK, f"{len(rules)}টি watch rule ঠিক আছে", f"{len(rules)} watch rule(s) valid"))

    # coding projects (names only; an invalid project is never started)
    from .sessions import parse_projects

    projects, project_problems = parse_projects(settings)
    if not settings.coding_projects:
        out.append(Check(OK, "coding_projects নেই (কোডিং সেশন বন্ধ)", "no coding_projects (coding sessions are off)"))
    else:
        for prob in project_problems:
            out.append(Check(WARN, f"coding_projects সমস্যা: {prob}", f"coding_projects problem: {prob}"))
        if projects:
            out.append(Check(OK, f"{len(projects)}টি কোডিং প্রজেক্ট ঠিক আছে", f"{len(projects)} coding project(s) valid"))
    ttl = settings.token_ttl_days
    if isinstance(ttl, int) and not isinstance(ttl, bool) and ttl > 0:
        out.append(Check(OK, f"টোকেন {ttl} দিন পরে মেয়াদোত্তীর্ণ হবে", f"phone tokens expire after {ttl} day(s)"))
    else:
        out.append(Check(WARN, "টোকেনের মেয়াদ নেই (token_ttl_days = 0); হারানো ফোন revoke করুন",
                         "tokens never expire (token_ttl_days = 0); revoke a lost phone"))
    from .localai import LocalAIError, check_local_endpoint

    if settings.ai_provider not in ("anthropic", "local"):
        out.append(Check(WARN, "ai_provider অবৈধ (anthropic বা local)", "ai_provider is invalid (anthropic or local)"))
    if settings.ai_provider == "local" or settings.ai_fallback_to_local:
        try:
            check_local_endpoint(settings.ai_local_endpoint)
            if not str(settings.ai_local_model or "").strip():
                raise LocalAIError("ai_local_model is empty")
            out.append(Check(OK, "লোকাল AI কনফিগার করা (শুধু পড়ার টুল)", "local AI is configured (read-only tools only)"))
        except LocalAIError as exc:
            out.append(Check(WARN, f"লোকাল AI কনফিগারেশনে সমস্যা: {exc}", f"local AI config problem: {exc}"))
    else:
        out.append(Check(OK, "লোকাল AI ফলব্যাক বন্ধ (ডিফল্ট)", "local AI fallback is off (default)"))
    from .gui import GuiPolicy

    gp = GuiPolicy.from_settings(settings)
    if not gp.enabled:
        out.append(Check(OK, "GUI এজেন্ট মোড বন্ধ (ডিফল্ট)", "GUI agent mode is off (default)"))
    elif not gp.allowed_apps:
        out.append(Check(WARN, "GUI মোড চালু কিন্তু allowed_apps খালি; কোনো ইনপুট চলবে না",
                         "GUI mode is on but allowed_apps is empty; no input will be accepted"))
    else:
        out.append(Check(WARN, f"GUI মোড চালু ({', '.join(sorted(gp.allowed_apps))}); আসল পর্দায় পরীক্ষা করা হয়নি",
                         f"GUI mode is ON for {', '.join(sorted(gp.allowed_apps))}; never verified on a real screen"))
    rd = str(settings.remote_desktop_app or "").strip().lower()
    if rd in {str(k).strip().lower() for k in settings.allowed_apps}:
        out.append(Check(OK, "রিমোট ডেস্কটপ অ্যাপ allowed_apps-এ আছে", "the remote desktop app is in allowed_apps"))
    else:
        out.append(Check(WARN, "রিমোট ডেস্কটপ (RustDesk) allowed_apps-এ নেই; remote_desktop_start চলবে না",
                         "the remote desktop app (RustDesk) is not in allowed_apps; remote_desktop_start will not run"))

    # wake capability, adapters, Tailscale, backup interface (MACs shown only here, locally)
    from . import wakeinfo

    caps = (wake_probe or wakeinfo.wake_capabilities)()
    if not caps.get("known"):
        out.append(Check(WARN, "জাগানোর ক্ষমতা জানা যায়নি (Windows/powercfg দরকার)",
                         "wake capability unknown (needs Windows and powercfg)"))
    else:
        out.append(Check(OK, f"wake_armed ডিভাইস: {len(caps['armed'])}, wake_programmable: {len(caps['programmable'])}",
                         f"wake_armed devices: {len(caps['armed'])}, wake_programmable: {len(caps['programmable'])}"))
        for key, label in (("wifi_wake_from_sleep", "Wi-Fi"), ("ethernet_wake", "Ethernet")):
            lvl = OK if caps[key] == "yes" else WARN
            out.append(Check(lvl, f"{label} দিয়ে জাগানো: {caps[key]}",
                             f"wake via {label}: {caps[key]} (see powercfg /devicequery wake_programmable)"))
    adapter_list = (adapter_probe or wakeinfo.adapters)()
    for a in adapter_list:
        ips = ", ".join(a["ipv4"]) or "-"
        mac_bn = f" MAC {a['mac'] or '-'} (শুধু এখানে দেখানো)" if show_mac else ""
        mac_en = f" MAC {a['mac'] or '-'} (shown locally only)" if show_mac else ""
        out.append(Check(OK, f"অ্যাডাপ্টার {a['name']}: {ips}{mac_bn}", f"adapter {a['name']}: {ips}{mac_en}"))
    if caps.get("known") or netadapter_probe:
        rows = (netadapter_probe or (lambda: wakeinfo.parse_netadapter_csv(
            wakeinfo.default_adapter_runner()[1])))()
        report = wakeinfo.adapter_wake_report(caps, rows)
        for r, line in zip(report, wakeinfo.verdict_lines(report)):
            lvl = OK if r["armed"] == "yes" and r["connected"] == "yes" else WARN
            out.append(Check(lvl, f"{r['kind']} জাগানো: {line}",
                             f"{line} [programmable {r['programmable']}, armed {r['armed']}, "
                             f"connected {r['connected']}]"))
    if wakeinfo.tailscale_present(adapter_list):
        out.append(Check(OK, "Tailscale ঠিকানা আছে", "a Tailscale address is present"))
    else:
        out.append(Check(WARN, "Tailscale ঠিকানা নেই (Tailscale চালু/লগইন করুন)",
                         "no Tailscale address present (start/sign in to Tailscale)"))
    backup = (settings.backup_adapter_name or "").strip()
    if not backup:
        out.append(Check(WARN, "backup_adapter_name সেট নেই (SIM/টেদার অ্যাডাপ্টারের নাম দিন)",
                         "backup_adapter_name not set (name of the SIM/tether adapter)"))
    elif any(a["name"].lower() == backup.lower() for a in adapter_list):
        out.append(Check(OK, "ব্যাকআপ ইন্টারফেস আছে", "the backup interface exists"))
    else:
        out.append(Check(WARN, "ব্যাকআপ ইন্টারফেস এখন নেই (টেদার/ডঙ্গল লাগান)",
                         "the backup interface is not present now (plug in the tether/dongle)"))
    unknown = getattr(settings, "unknown_keys", [])
    if unknown:
        out.append(Check(WARN, f"config.json-এ অচেনা কী (বানান ভুল?): {', '.join(unknown[:8])}; এগুলো উপেক্ষা করা হয়",
                         f"config.json has unknown keys (typo?): {', '.join(unknown[:8])}; they are ignored"))
    return out


def format_report(checks: list[Check]) -> str:
    lines = [c.line() for c in checks]
    fails = sum(c.level == FAIL for c in checks)
    warns = sum(c.level == WARN for c in checks)
    lines.append(f"সারাংশ / Summary: {fails} fail, {warns} warn")
    return "\n".join(lines)
