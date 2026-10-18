"""Fixes from the session-3 independent review (each written to fail before the fix)."""
import pytest
from fastapi.testclient import TestClient

from agent import wakeinfo
from agent.server import create_app


def test_open_app_cannot_start_the_remote_desktop_helper(engine, settings, launched):
    settings.allowed_apps = {"notepad": ["notepad.exe"], "rustdesk": ["rustdesk.exe"]}
    r = engine.run("open_app", {"name": "rustdesk"}, "t", "http")
    assert not r.ok and launched == []
    assert not engine.run("open_app", {"name": "RustDesk "}, "t", "ai").ok and launched == []
    assert engine.run("open_app", {"name": "notepad"}, "t", "http").ok       # others unaffected


def test_remote_desktop_start_still_works_for_the_high_risk_path(engine, settings, launched):
    settings.allowed_apps = {"rustdesk": ["rustdesk.exe"]}
    http = TestClient(create_app(settings, engine))
    code = engine.pairing.create_code()
    auth = {"Authorization": f"Bearer {http.post('/pair', json={'code': code}).json()['token']}"}
    first = http.post("/actions/remote_desktop_start", json={"params": {}}, headers=auth).json()
    assert first["status"] == "confirmation_required" and launched == []
    ok = http.post("/actions/remote_desktop_start", json={"params": {}, "confirm_token": first["confirm_token"]},
                   headers=auth).json()
    assert ok["status"] == "ok" and launched == [["rustdesk.exe"]]


def test_gui_start_that_cannot_run_is_refused_before_a_confirmation(engine, settings):
    http = TestClient(create_app(settings, engine))
    code = engine.pairing.create_code()
    auth = {"Authorization": f"Bearer {http.post('/pair', json={'code': code}).json()['token']}"}
    r = http.post("/actions/gui_session_start", json={"params": {"minutes": "3"}}, headers=auth)
    assert "confirm_token" not in r.text and r.json().get("status") != "confirmation_required"
    settings.gui_agent = {"enabled": True, "allowed_apps": ["notepad"], "max_session_minutes": 5}
    for bad in ("0", "6", "x", "", "٣"):
        r = http.post("/actions/gui_session_start", json={"params": {"minutes": bad}}, headers=auth)
        assert "confirm_token" not in r.text, bad
    r = http.post("/actions/gui_session_start", json={"params": {"minutes": "3"}}, headers=auth)
    assert r.json()["status"] == "confirmation_required"


def test_adapter_names_lose_control_characters():
    csv_text = '"Name","InterfaceDescription","Status","MacAddress"\r\n"Wi-Fi","Intel\n  2. Evil \x1b[31m","Up","AA-BB-CC-00-11-22"\r\n'
    rows = wakeinfo.parse_netadapter_csv(csv_text)
    assert rows and all("\n" not in v and "\x1b" not in v for v in rows[0].values())


def test_secrets_h_is_blocked_by_the_commit_hook():
    import importlib.util
    from pathlib import Path

    spec = importlib.util.spec_from_file_location(
        "pc", Path(__file__).resolve().parents[1] / "scripts" / "precommit_check.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert "secrets.h" in mod.BLOCKED_NAMES and "secrets.example.h" not in mod.BLOCKED_NAMES
