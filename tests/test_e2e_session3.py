"""Session 3: one scripted flow through the real FastAPI app.

Fakes only: FakeRunner (no shutdown/sleep), a fake UDP sender, a fake Anthropic client, a fake
process launcher and a fake GUI backend. At the end the audit table, the AI history and every
HTTP body are searched for tokens, MAC addresses, image bytes and the typed text.
"""
import base64
import sys

import pytest
from fastapi.testclient import TestClient

from agent.actions import ProcessManager
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use
from .test_phase5_images import png_bytes
from .test_phase6_sessions import FakePopen
from .test_phase7_gui import FakeBackend, FakeFg

PY = sys.executable
WIFI_MAC = "AA:BB:CC:00:11:22"
ETH_MAC = "AA-BB-CC-33-44-55"
IMAGE = png_bytes(64, 48)
IMAGE_B64 = base64.b64encode(IMAGE).decode()


def all_db_text(engine) -> str:
    out = []
    with engine.db.conn() as c:
        for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
            for row in c.execute(f"SELECT * FROM {t}"):
                out.append(" | ".join(str(v) for v in tuple(row)))
    return "\n".join(out)


@pytest.fixture
def flow(engine, settings, files, runner, monkeypatch):
    settings.wake_targets = {"desktop": {"mac": WIFI_MAC, "broadcast": "192.168.1.255"},
                             "desktop-eth": {"mac": ETH_MAC}}
    settings.coding_projects = {"api": {"path": str(files), "argv": [PY, "-c", "print('hi')"]}}
    sent = []
    engine.ctx.wol_sender = lambda pkt, bc, port: sent.append((pkt, bc, port))
    engine.ctx.popen = FakePopen
    monkeypatch.setattr(ProcessManager, "kill_tree", staticmethod(lambda proc: proc.kill()))
    engine.ctx.wake_probe = lambda: {"known": True, "armed": ["Intel(R) Dual Band Wireless-N 7260"],
                                     "programmable": [], "wifi_wake_from_sleep": "yes",
                                     "ethernet_wake": "no", "summary": "can wake from Sleep: yes"}
    engine.backend, engine.fg = FakeBackend(), FakeFg()
    engine.ctx.gui_backend = lambda: engine.backend         # set before ctx.gui is first built
    engine.ctx.gui_foreground = lambda: engine.fg
    client = FakeClient([
        resp([tool_use("t1", "shutdown")], "tool_use"),
        resp([text("I asked for a shutdown; confirm on the phone if you really want it.")]),
    ])
    http = TestClient(create_app(settings, engine, ai_client=client))
    FakePopen.made = []
    yield engine, settings, http, runner, sent, client
    for p in FakePopen.made:
        if p.code is None:
            p.finish(-1)


def pair(http, engine, role, name):
    code = engine.pairing.create_code(role)
    body = http.post("/pair", json={"code": code, "device_name": name}).json()
    return {"Authorization": f"Bearer {body['token']}"}, body["token"]


def confirmed(http, auth, action, params=None):
    """The two-step flow like the phone does it: ask, then confirm with the issued token."""
    first = http.post(f"/actions/{action}", json={"params": params or {}}, headers=auth)
    assert first.json()["status"] == "confirmation_required", first.text
    return http.post(f"/actions/{action}", json={"params": params or {},
                                                 "confirm_token": first.json()["confirm_token"]},
                     headers=auth)


def test_the_whole_flow(flow):
    engine, settings, http, runner, sent, client = flow
    seen_bodies: list[str] = []

    def call(method, url, **kw):
        r = http.request(method, url, **kw)
        seen_bodies.append(r.text)
        return r

    owner, owner_token = pair(http, engine, "owner", "owner-phone")
    viewer, viewer_token = pair(http, engine, "viewer", "family-phone")

    # ---- health: small, no secrets; the owner sees more than strangers
    assert call("GET", "/health").json()["status"] == "ok"
    assert call("GET", "/health", headers=owner).status_code == 200
    assert call("GET", "/devices", headers=viewer).status_code in (401, 403, 404)

    # ---- power_capabilities: honest text, no MAC
    caps = call("POST", "/actions/power_capabilities", json={"params": {}}, headers=owner).json()
    assert caps["status"] == "ok" and "yes" in caps["message"].lower() and "AA:BB" not in caps["message"]

    # ---- wake_computer: one exact magic packet; the viewer may not
    ok = call("POST", "/actions/wake_computer", json={"params": {"name": "desktop"}}, headers=owner)
    assert ok.json()["status"] == "ok" and len(sent) == 1
    pkt, bc, port = sent[0]
    assert pkt == b"\xff" * 6 + bytes.fromhex("AABBCC001122") * 16 and bc == "192.168.1.255" and port == 9
    assert call("POST", "/actions/wake_computer", json={"params": {"name": "desktop-eth"}},
                headers=viewer).status_code == 403
    assert call("POST", "/actions/wake_computer", json={"params": {"name": "../x"}},
                headers=owner).json()["status"] != "ok"
    assert len(sent) == 1

    # ---- sleep: needs the two-step confirmation; viewer denied
    first = call("POST", "/actions/sleep", json={"params": {}}, headers=owner).json()
    assert first["status"] == "confirmation_required" and runner.calls == []
    assert call("POST", "/actions/sleep", json={"params": {}}, headers=viewer).status_code == 403
    done = call("POST", "/actions/sleep", json={"params": {}, "confirm_token": first["confirm_token"]},
                headers=owner).json()
    assert done["status"] == "ok" and len(runner.calls) == 1          # the FAKE runner got it
    runner.calls.clear()

    # ---- AI task with a picture that tries to trigger a shutdown: only a pending confirmation
    r = call("POST", "/ai/tasks", headers=owner, json={
        "instruction": "what is on this picture?",
        "images": [{"media_type": "image/png", "data": IMAGE_B64}]})
    assert r.status_code == 200, r.text
    body = r.json()
    assert [p["action"] for p in body["pending_confirmations"]] == ["shutdown"]
    assert runner.calls == []
    assert call("POST", "/ai/tasks", headers=viewer, json={"instruction": "hi"}).status_code == 403
    pend = call("GET", "/ai/pending", headers=owner).json()
    assert len(pend) == 1
    assert call("POST", "/ai/cancel", json={"confirm_token": pend[0]["confirm_token"]},
                headers=owner).status_code == 200
    assert runner.calls == []

    # ---- coding session start/stop (own processes only, confirmation, fake Popen)
    started = confirmed(http, owner, "coding_session_start", {"name": "api"})
    assert started.json()["status"] == "ok" and len(FakePopen.made) == 1
    assert call("POST", "/actions/coding_session_start", json={"params": {"name": "api"}},
                headers=viewer).status_code == 403
    stopped = confirmed(http, owner, "coding_session_stop", {"name": "api"})
    assert stopped.json()["status"] == "ok" and FakePopen.made[0].killed

    # ---- GUI session: refused while disabled ...
    gate = call("POST", "/actions/gui_session_start", json={"params": {"minutes": "3"}}, headers=owner).json()
    if gate["status"] == "confirmation_required":
        gate = call("POST", "/actions/gui_session_start", headers=owner,
                    json={"params": {"minutes": "3"}, "confirm_token": gate["confirm_token"]}).json()
    assert gate["status"] != "ok" and not engine.ctx.gui.active()
    # ... and works with a fake backend once the owner turned it on
    settings.gui_agent = {"enabled": True, "allowed_apps": ["notepad"], "max_session_minutes": 5,
                          "max_actions": 6}
    assert confirmed(http, owner, "gui_session_start", {"minutes": "3"}).json()["status"] == "ok"
    assert engine.ctx.gui.active()
    typed = "TYPED-SECRET-TEXT-123"
    typed_r = call("POST", "/actions/gui_type", json={"params": {"text": typed}}, headers=owner).json()
    assert typed_r["status"] == "ok", typed_r
    assert engine.backend.calls and engine.backend.calls[-1][0] == "type"       # the FAKE backend got it
    assert call("POST", "/actions/gui_click", json={"params": {"x": "10", "y": "10"}},
                headers=viewer).status_code == 403

    # ---- emergency stop ends everything
    es = call("POST", "/actions/emergency_stop", json={"params": {}}, headers=owner)
    assert es.status_code == 200
    assert not engine.ctx.gui.active()
    assert engine.ctx.stop_event.is_set()

    # ---- the books: audit rows exist, and no sink holds a secret, a MAC, picture bytes or typed text
    rows = engine.audit.recent(200)
    actions = {row["action"] for row in rows}
    assert {"pair", "power_capabilities", "wake_computer", "sleep", "shutdown", "ai_task", "ai_cancel",
            "coding_session_start", "coding_session_stop", "gui_session_start", "gui_type",
            "emergency_stop"} <= actions, sorted(actions)
    # the denied viewer calls and the unconfirmed AI shutdown never ran anything real
    assert all(c[:2] == ["shutdown", "/a"] for c in runner.calls)       # only emergency_stop's cancel
    db_text = all_db_text(engine)
    bodies = "\n".join(seen_bodies)
    leaks = (owner_token, viewer_token, WIFI_MAC, ETH_MAC, WIFI_MAC.replace(":", "-"), WIFI_MAC.lower(),
             "aabbcc001122", "AABBCC001122", ETH_MAC.replace("-", ":"), IMAGE_B64[:60], typed)
    for secret in leaks:
        assert secret not in db_text, ("db", secret[:12])
        assert secret not in bodies, ("http", secret[:12])
    # +N images is all the history keeps
    hist = call("GET", "/ai/history", headers=owner).json()
    assert "+1 image" in str(hist)
