"""Command line: python -m agent.main <command>"""
from __future__ import annotations

import argparse
import getpass
import logging
import secrets
import sys
import time

from .config import Settings
from .engine import Engine
from .security import hash_secret
from .sms import normalize_number


def cmd_serve(settings: Settings, _args) -> int:
    import uvicorn

    from .server import create_app

    from .logging_setup import setup_logging

    setup_logging(settings)
    if settings.host == "0.0.0.0":
        msg = ("WARNING: host 0.0.0.0 exposes the agent on every network. "
               "Prefer your Tailscale IP.")
        logging.getLogger("cortex").warning(msg)
        if sys.stderr:
            print(msg, file=sys.stderr)
    engine = Engine(settings)
    if settings.power_watch:
        from .notify import Notifier
        from .power import PowerWatcher

        PowerWatcher(engine, notifier=Notifier.from_settings(settings)).start()
    app = create_app(settings, engine)
    # log_config=None keeps the rotating, redacting file handler we installed.
    uvicorn.run(app, host=settings.host, port=settings.port, log_config=None,
                log_level="info")
    return 0


def cmd_doctor(settings: Settings, _args) -> int:
    from .doctor import FAIL, format_report, run_checks

    checks = run_checks(settings)
    print(format_report(checks))
    return 1 if any(c.level == FAIL for c in checks) else 0


def cmd_init_config(settings: Settings, _args) -> int:
    if settings.config_path.exists():
        print(f"config.json আগে থেকেই আছে, কিছু বদলানো হয়নি / config.json already exists, "
              f"left untouched: {settings.config_path}")
        return 0
    # Fresh defaults for this Windows user: Downloads/Documents, notepad/
    # calculator/explorer, no scripts, nothing network-facing beyond loopback.
    fresh = Settings(data_dir=settings.data_dir)
    fresh.save()
    print(f"config.json তৈরি হয়েছে / created: {fresh.config_path}")
    print("allowed_roots:", ", ".join(str(p) for p in fresh.allowed_roots))
    print("allowed_apps:", ", ".join(fresh.allowed_apps))
    return 0


def cmd_pair(settings: Settings, _args) -> int:
    code = Engine(settings).pairing.create_code()
    print(f"Pairing code: {code}  (valid {settings.pairing_ttl_seconds // 60} min, one use)")
    return 0


def cmd_devices(settings: Settings, _args) -> int:
    for d in Engine(settings).pairing.list_devices():
        seen = (time.strftime("%Y-%m-%d %H:%M", time.localtime(d["last_seen"]))
                if d["last_seen"] else "never")
        flag = " (revoked)" if d["revoked"] else ""
        print(f"{d['id']}: {d['name']}  last seen {seen}{flag}")
    return 0


def cmd_revoke(settings: Settings, args) -> int:
    ok = Engine(settings).pairing.revoke(args.device_id)
    print("Revoked." if ok else "No such device.")
    return 0 if ok else 1


def cmd_audit(settings: Settings, args) -> int:
    for row in reversed(Engine(settings).audit.recent(args.limit)):
        when = time.strftime("%m-%d %H:%M:%S", time.localtime(row["ts"]))
        print(f"{when} {row['via']:<4} {row['actor']:<18} {row['action']:<16} "
              f"{row['status']:<9} {row['detail']}")
    return 0


def cmd_export_audit(settings: Settings, args) -> int:
    from .audit import export_csv

    engine = Engine(settings)
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = settings.data_dir / f"audit-{stamp}.csv"
    n = export_csv(engine.db, path, args.days)
    print(f"{n} row(s) -> {path}")
    return 0


def cmd_ask(settings: Settings, args) -> int:
    from .ai import AIUnavailable, Orchestrator

    engine = Engine(settings)
    try:
        result = Orchestrator(engine).run(" ".join(args.instruction), 0, "cli")
    except AIUnavailable as exc:
        print(f"AI unavailable: {exc}", file=sys.stderr)
        return 1
    for step in result.steps:
        mark = "ok " if step["ok"] else "ERR"
        print(f"  [{mark}] {step['tool']} {step['input']} -> {step['message']}")
    print(result.reply)
    for p in result.pending_confirmations:
        print(f"(waiting for phone confirmation: {p['action']})")
    print(f"tokens used: {result.tokens_used}")
    return 0 if result.ok else 2


def cmd_ai_usage(settings: Settings, _args) -> int:
    from .ai import Orchestrator

    u = Orchestrator(Engine(settings)).usage_today()
    print(f"Today: {u['total_tokens']} / {u['daily_cap']} tokens, {u['requests']} request(s)")
    return 0


def cmd_sms_setup(settings: Settings, args) -> int:
    from . import totp

    numbers = {normalize_number(n) for n in args.numbers}
    if args.totp:
        secret = totp.new_secret()
        try:
            how = totp.save_secret(settings.data_dir, secret)
        except OSError as exc:
            print(f"Could not store the TOTP secret ({type(exc).__name__}).", file=sys.stderr)
            return 1
        settings.sms_mode = "totp"
        settings.sms_pin_hash = ""          # the static PIN stops working
        if how != "dpapi":
            print("WARNING: not on Windows, so the secret is stored in a file with "
                  "permissions 600 (not encrypted).", file=sys.stderr)
    else:
        pin = getpass.getpass("Choose an SMS PIN (4-12 digits): ")
        if not pin.isdigit() or not 4 <= len(pin) <= 12:
            print("PIN must be 4-12 digits.", file=sys.stderr)
            return 1
        if pin != getpass.getpass("Repeat PIN: "):
            print("PINs do not match.", file=sys.stderr)
            return 1
        settings.sms_pin_hash = hash_secret(pin)
        settings.sms_mode = "pin"
        totp.delete_secret(settings.data_dir)
        secret = ""
    settings.sms_allowed_numbers = sorted(n for n in numbers if n)
    gateway = secrets.token_urlsafe(24)
    settings.gateway_secret_hash = hash_secret(gateway)
    settings.save()
    print("SMS control enabled for:", ", ".join(settings.sms_allowed_numbers))
    print("\nGateway secret (shown ONCE, put it in the SMS gateway app as the "
          "X-Gateway-Secret header):")
    print(gateway)
    if args.totp:
        print("\nTOTP secret (shown ONCE, never saved in readable form). Add it to an "
              "authenticator app as a time-based key, 6 digits, 30 s:")
        print(secret)
        print("SMS format: SHUTDOWN 482913  (the 6-digit code from the app, used once)")
    else:
        print("\nNote: PIN mode has no replay protection. Prefer: sms-setup --totp")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="cortex-one")
    p.add_argument("--data-dir", help="override the data folder")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("serve", help="start the agent").set_defaults(fn=cmd_serve)
    sub.add_parser("pair", help="print a one-time pairing code").set_defaults(fn=cmd_pair)
    sub.add_parser("devices", help="list paired phones").set_defaults(fn=cmd_devices)
    r = sub.add_parser("revoke", help="revoke a phone")
    r.add_argument("device_id", type=int)
    r.set_defaults(fn=cmd_revoke)
    a = sub.add_parser("audit", help="show recent actions")
    a.add_argument("--limit", type=int, default=30)
    a.set_defaults(fn=cmd_audit)
    q = sub.add_parser("ask", help="give the AI operator an instruction (needs ANTHROPIC_API_KEY)")
    q.add_argument("instruction", nargs="+")
    q.set_defaults(fn=cmd_ask)
    e = sub.add_parser("export-audit", help="write a redacted CSV of recent audit entries")
    e.add_argument("--days", type=int, default=7)
    e.set_defaults(fn=cmd_export_audit)
    sub.add_parser("ai-usage", help="today's AI token use").set_defaults(fn=cmd_ai_usage)
    sub.add_parser("doctor", help="check the setup").set_defaults(fn=cmd_doctor)
    sub.add_parser("init-config", help="write a default config.json if none exists"
                   ).set_defaults(fn=cmd_init_config)
    s = sub.add_parser("sms-setup", help="enable SMS control")
    s.add_argument("numbers", nargs="+", help="phone numbers allowed to command the laptop")
    s.add_argument("--totp", action="store_true",
                   help="use one-time authenticator codes instead of a static PIN")
    s.set_defaults(fn=cmd_sms_setup)
    args = p.parse_args(argv)
    for stream in (sys.stdout, sys.stderr):  # Bangla output on legacy Windows consoles
        if stream is not None and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    settings = Settings.load(args.data_dir)
    return args.fn(settings, args)


if __name__ == "__main__":
    raise SystemExit(main())
