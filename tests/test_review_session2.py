"""Findings of the independent review of session 2 (each test failed before its fix)."""
import urllib.request

import pytest
from fastapi.testclient import TestClient

from agent.gui import Foreground
from agent.localai import LocalClient
from agent.server import create_app

from .test_phase7_gui import FakeBackend, FakeFg, NOTEPAD, gx, run, shot, start  # noqa: F401


@pytest.fixture
def http(engine, settings):
    return TestClient(create_app(settings, engine))


def pair(http, engine, role="owner"):
    code = engine.pairing.create_code(role)
    return {"Authorization": f"Bearer {http.post('/pair', json={'code': code}).json()['token']}"}


# 1. body caps for every POST route; no chunked bodies
@pytest.mark.parametrize("path", ["/pair", "/actions/status", "/ai/tasks", "/sms/inbound", "/emergency-stop"])
def test_chunked_requests_are_refused_on_every_post_route(http, path):
    def chunks():
        yield b"{}"
    r = http.post(path, content=chunks(), headers={"content-type": "application/json"})
    assert r.status_code == 411


@pytest.mark.parametrize("path", ["/pair", "/actions/status", "/sms/inbound"])
def test_other_post_routes_have_a_small_body_cap(http, path):
    r = http.post(path, json={"x": "y" * 200_000})
    assert r.status_code == 413


# 2 + 3 (BLE session answer matching and counter desync) are Dart: mobile/test/wake_test.dart


# 5. GUI: the picture and the clicks stay inside the front window
def test_screenshot_is_cropped_to_the_front_window(gx):
    start(gx)
    gx.fg.fg = Foreground("notepad", "Untitled - Notepad", (100, 100, 300, 260))
    r = shot(gx)
    assert (r.data["width"], r.data["height"]) == (200, 160)


def test_click_maps_to_the_real_screen_with_the_crop_offset(gx):
    start(gx)
    gx.fg.fg = Foreground("notepad", "Untitled - Notepad", (100, 100, 300, 260))
    shot(gx)
    assert run(gx, "gui_click", x="10", y="20").ok
    assert gx.backend.calls == [("click", 110, 120, False)]
    assert not run(gx, "gui_click", x="200", y="5").ok


def test_a_blocked_window_on_top_at_the_click_point_refuses_the_click(gx):
    start(gx)
    shot(gx)
    gx.fg.point = Foreground("keepass", "KeePass", (0, 0, 640, 480))
    r = run(gx, "gui_click", x="10", y="10")
    assert not r.ok and gx.backend.calls == []
    gx.fg.point = Foreground("chrome", "Home", (0, 0, 640, 480))     # not an approved app
    assert not run(gx, "gui_click", x="10", y="10").ok


# 6. local model: no proxy
def test_local_client_never_uses_a_proxy(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    c = LocalClient("http://127.0.0.1:11434", "m")
    proxies = [h for h in c._open.__self__.handlers if isinstance(h, urllib.request.ProxyHandler)]
    assert all(p.proxies == {} for p in proxies)


# 7. paths never go to a viewer
def test_take_screenshot_does_not_reveal_the_folder(engine, http):
    r = engine.run("take_screenshot", {}, "t", "http")
    assert r.ok and "folder" not in r.data and str(engine.settings.screenshots_dir) not in str(r.data)
    v = pair(http, engine, "viewer")
    body = http.post("/actions/take_screenshot", json={}, headers=v).json()
    assert "folder" not in body["data"]


# 8. unauthenticated /health does not say when the machine was put to sleep
def test_health_hides_the_last_power_request_from_strangers(engine, http, runner):
    engine.run("sleep", {}, "t", "cli")
    assert "last_power_request" not in http.get("/health").json()
    h = pair(http, engine)
    assert http.get("/health", headers=h).json()["last_power_request"]["action"] == "sleep"


# 9. typed text is also kept out of the task steps
def test_typed_text_is_not_in_the_task_steps(gx):
    from agent.ai import Orchestrator
    from .fake_anthropic import FakeClient, resp, text, tool_use
    start(gx)
    client = FakeClient([resp([tool_use("t1", "gui_type", text="zebra-secret-9")], "tool_use"), resp([text("ok")])])
    r = Orchestrator(gx, client=client, today=lambda: "2026-10-17").run("type", 1, "phone")
    assert "zebra-secret-9" not in str(r.steps)


# 4. installer takes ownership of the script folder
def test_installer_resets_owner_and_acl_of_the_script_folder():
    from pathlib import Path
    t = (Path(__file__).resolve().parents[1] / "scripts" / "install-network-failover.ps1").read_text(encoding="utf-8")
    assert "/setowner" in t and "/reset" in t and t.index("/setowner") < t.index("/inheritance:r")
