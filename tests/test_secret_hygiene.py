"""Run one full scripted session, then grep EVERY output for secrets.

Sinks searched: the rotating log file, every table in the SQLite database, the
CLI output (doctor, audit, export-audit, ai-history, devices, ai-usage) and all
HTTP responses and headers. Nothing may contain the device token, the pairing
code, the SMS PIN, a TOTP code, the gateway secret, the TOTP secret, the API key
or the Authorization header. (Confirmation tokens are single-use and are returned
only to the device that asked; they must still never reach logs, audit or the DB.)
"""
import base64
import json
import logging
import re

import pytest
from fastapi.testclient import TestClient

from agent import main as cli
from agent import security, totp
from agent.logging_setup import setup_logging
from agent.security import hash_secret
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use

API_KEY = "sk-ant-api03-" + "ZxQ9-" * 10 + "SENTINEL"
PAIR_CODE = "482913"
PIN = "9035712"
GATEWAY = "gw-secret-Sentinel-7731"
TOTP_SECRET = base64.b32encode(b"12345678901234567890").decode()
TOTP_T = 1_700_000_010.0


@pytest.fixture
def session(engine, settings, monkeypatch, capsys):
    monkeypatch.setenv("ANTHROPIC_API_KEY", API_KEY)
    monkeypatch.setattr(security.secrets, "randbelow", lambda n: int(PAIR_CODE))
    settings.sms_pin_hash = hash_secret(PIN, iterations=1000)
    settings.gateway_secret_hash = hash_secret(GATEWAY, iterations=1000)
    handler = setup_logging(settings)
    logging.getLogger("cortex").setLevel(logging.DEBUG)
    # the model's call "fails" with a message that contains the key (SDKs can echo headers)
    client = FakeClient([
        resp([tool_use("t1", "shutdown")], "tool_use"),
        resp([text("waiting for your confirmation")]),
        RuntimeError(f"401 invalid x-api-key {API_KEY} Authorization: Bearer abc.def"),
    ])
    http = TestClient(create_app(settings, engine, ai_client=client))
    responses = []

    def call(method, url, **kw):
        r = http.request(method, url, **kw)
        responses.append((url, r))
        return r

    yield engine, settings, call, responses, capsys
    logging.getLogger().removeHandler(handler)
    handler.close()


def all_db_text(engine) -> str:
    out = []
    with engine.db.conn() as c:
        tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        for t in tables:
            for row in c.execute(f"SELECT * FROM {t}"):
                out.append(" | ".join(str(v) for v in tuple(row)))
    return "\n".join(out)


def test_full_session_leaks_nothing(session, tmp_path):
    engine, settings, call, responses, capsys = session
    pin_token = {}

    # ---- pairing: wrong codes first (lockout), then the right one
    for _ in range(3):
        assert call("POST", "/pair", json={"code": "000001", "device_name": "evil"}).status_code == 403
    code = engine.pairing.create_code()
    assert code == PAIR_CODE
    r = call("POST", "/pair", json={"code": code, "device_name": "my phone"})
    token = r.json()["token"]
    auth = {"Authorization": f"Bearer {token}"}

    # ---- bad / missing tokens
    assert call("GET", "/audit").status_code == 401
    assert call("GET", "/audit", headers={"Authorization": "Bearer not-a-real-token-123"}).status_code == 401

    # ---- normal use
    for url in ("/actions", "/audit", "/alerts", "/watch", "/capabilities", "/ai/pending",
                "/ai/history", "/ai/usage", "/screenshots"):
        call("GET", url, headers=auth)
    call("POST", "/actions/status", json={}, headers=auth)
    call("POST", "/actions/list_files", json={"params": {"path": "C:\\Windows"}}, headers=auth)
    first = call("POST", "/actions/restart", json={}, headers=auth).json()
    confirm = first["confirm_token"]
    call("POST", "/actions/restart", json={"confirm_token": confirm}, headers=auth)
    call("POST", "/actions/restart", json={"confirm_token": "reused-" + confirm}, headers=auth)

    # ---- AI: pending confirmation, cancel, then a failing model call carrying the key
    ai1 = call("POST", "/ai/tasks", json={"instruction": f"shut down, my pin is {PIN}"}, headers=auth)
    ai_confirm = ai1.json()["pending_confirmations"][0]["confirm_token"]
    call("POST", "/ai/cancel", json={"confirm_token": ai_confirm}, headers=auth)
    call("POST", "/ai/confirm", json={"confirm_token": ai_confirm}, headers=auth)
    ai2 = call("POST", "/ai/tasks", json={"instruction": "second task"}, headers=auth)
    assert ai2.status_code == 200 and not ai2.json()["pending_confirmations"]
    # (the script has no third response: that is fine, the second call consumed the failure)

    # ---- SMS: wrong gateway secret, wrong PIN, right PIN (+ TOTP mode with a replay)
    sms = {"from": "01711111111", "text": f"STATUS {PIN}"}
    call("POST", "/sms/inbound", json=sms, headers={"X-Gateway-Secret": "wrong-secret-xyz"})
    call("POST", "/sms/inbound", json={"from": "01711111111", "text": "STATUS 1234"},
         headers={"X-Gateway-Secret": GATEWAY})
    call("POST", "/sms/inbound", json=sms, headers={"X-Gateway-Secret": GATEWAY})
    totp.save_secret(settings.data_dir, TOTP_SECRET)
    settings.sms_mode = "totp"
    code_now = totp.totp(TOTP_SECRET, TOTP_T)
    from agent.sms import SmsHandler
    handler = SmsHandler(engine, now=lambda: TOTP_T)
    handler.handle("01711111111", f"STATUS {code_now}")
    handler.handle("01711111111", f"STATUS {code_now}")        # replay
    engine.audit.log("device:x", "http", "x", {"token": token, "pin": PIN, "note": f"Bearer {token}"},
                     "ok", "params that name secrets are redacted")

    # ---- CLI outputs
    settings.save()
    out_all = []
    for argv in (["doctor"], ["audit", "--limit", "500"], ["export-audit", "--days", "1"],
                 ["ai-history"], ["devices"], ["ai-usage"], ["ask", "--dry-run", "hi"]):
        cli.main(["--data-dir", str(settings.data_dir), *argv])
        c = capsys.readouterr()
        out_all.append(c.out + c.err)
    export = "".join(p.read_text(encoding="utf-8-sig") for p in settings.data_dir.glob("audit-*.csv"))

    # ---- collect sinks
    logging.shutdown()
    log_text = "".join(p.read_text(encoding="utf-8", errors="replace")
                       for p in (settings.logs_dir).glob("agent.log*"))
    db_text = all_db_text(engine)
    cli_text = "\n".join(out_all)
    http_text = "\n".join(f"{u}\n{r.status_code}\n{dict(r.headers)}\n{r.text}" for u, r in responses)

    never_anywhere = {"api key": API_KEY, "api key body": "ZxQ9-ZxQ9", "pin": PIN,
                      "totp code": code_now, "gateway secret": GATEWAY,
                      "totp secret": TOTP_SECRET, "pairing code": PAIR_CODE}
    quiet_sinks = {"log": log_text, "database": db_text, "cli": cli_text, "export": export}
    for sink_name, blob in {**quiet_sinks, "http": http_text}.items():
        for what, secret in never_anywhere.items():
            assert secret not in blob, f"{what} leaked into {sink_name}"
        assert "Bearer abc.def" not in blob, sink_name
    for sink_name, blob in quiet_sinks.items():
        assert token not in blob, f"device token leaked into {sink_name}"
        for t in (confirm, ai_confirm):
            assert t not in blob, f"confirmation token leaked into {sink_name}"
        assert not re.search(r"(?i)authorization\s*[:=]\s*bearer\s+[A-Za-z0-9_\-\.]{8,}", blob), sink_name
    # the raw device token is shown once, by /pair, and nowhere else
    for url, r in responses:
        if url != "/pair":
            assert token not in r.text and token not in str(dict(r.headers)), url

    # sanity: the session really did produce output in every sink
    assert "pair" in db_text and "restart" in db_text and log_text.strip() and cli_text.strip()
    assert "***" in db_text                       # redaction happened, it was not just absent


def test_error_responses_do_not_echo_input_or_internals(session):
    engine, settings, call, responses, _ = session
    code = engine.pairing.create_code()
    token = call("POST", "/pair", json={"code": code, "device_name": "p"}).json()["token"]
    auth = {"Authorization": f"Bearer {token}"}
    probes = [
        ("GET", "/nope", {}), ("POST", "/actions/not_an_action", {"json": {}}),
        ("POST", "/actions/copy_file", {"json": {"params": {"src": "Z:\\secret", "dst": "\x00"}}}),
        ("POST", "/actions/shutdown", {"json": {"params": {"bogus": f"{API_KEY}"}}}),
        ("POST", "/ai/confirm", {"json": {"confirm_token": "x" * 200}}),
        ("POST", "/pair", {"json": {"code": "abc", "device_name": API_KEY}}),
        ("GET", "/screenshots/..%5C..%5Cwin.ini", {}),
    ]
    for method, url, kw in probes:
        r = call(method, url, headers=auth, **kw)
        body = r.text
        assert API_KEY not in body and token not in body, url
        assert "Traceback" not in body and "File \"" not in body, url
        assert "sqlite" not in body.lower(), url
