import pytest
from fastapi.testclient import TestClient

from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use


def build(engine, settings, script):
    client = FakeClient(script)
    app = create_app(settings, engine, ai_client=client)
    http = TestClient(app)
    code = engine.pairing.create_code()
    token = http.post("/pair", json={"code": code, "device_name": "phone"}).json()["token"]
    return http, {"Authorization": f"Bearer {token}"}, client


def test_ai_routes_need_a_token(engine, settings):
    http, _, client = build(engine, settings, [resp([text("x")])])
    assert http.post("/ai/tasks", json={"instruction": "hi"}).status_code == 401
    assert http.get("/ai/usage").status_code == 401
    assert client.calls == []


def test_ai_task_end_to_end(engine, settings, files):
    script = [resp([tool_use("t1", "list_files", path=str(files))], "tool_use"),
              resp([text("২টি আইটেম আছে।")])]
    http, auth, _ = build(engine, settings, script)
    r = http.post("/ai/tasks", json={"instruction": "ফাইল দেখাও"}, headers=auth)
    body = r.json()
    assert r.status_code == 200 and body["status"] == "ok"
    assert body["reply"] == "২টি আইটেম আছে।" and body["steps"][0]["tool"] == "list_files"
    usage = http.get("/ai/usage", headers=auth).json()
    assert usage["total_tokens"] == 240 and usage["daily_cap"] == settings.ai_daily_token_cap


def test_pending_shutdown_from_ai_is_confirmed_on_the_phone(engine, settings, runner):
    script = [resp([tool_use("t1", "shutdown")], "tool_use"), resp([text("Confirm on phone.")])]
    http, auth, _ = build(engine, settings, script)
    body = http.post("/ai/tasks", json={"instruction": "shut down"}, headers=auth).json()
    assert runner.calls == []
    token = body["pending_confirmations"][0]["confirm_token"]
    r = http.post("/actions/shutdown", json={"confirm_token": token}, headers=auth)
    assert r.json()["status"] == "ok"
    assert runner.calls == [["shutdown", "/s", "/t", "30"]]
    # and the token cannot be used a second time
    assert http.post("/actions/shutdown", json={"confirm_token": token},
                     headers=auth).status_code == 403


def test_instruction_limits_and_validation(engine, settings):
    http, auth, client = build(engine, settings, [resp([text("x")])])
    assert http.post("/ai/tasks", json={"instruction": ""}, headers=auth).status_code == 422
    assert http.post("/ai/tasks", json={"instruction": "x" * 2001}, headers=auth).status_code == 422
    assert http.post("/ai/tasks", json={}, headers=auth).status_code == 422
    assert client.calls == []


def test_ai_rate_limit(engine, settings):
    settings.ai_requests_per_minute = 2
    http, auth, _ = build(engine, settings, [resp([text("a")]) for _ in range(5)])
    codes = [http.post("/ai/tasks", json={"instruction": "hi"}, headers=auth).status_code
             for _ in range(4)]
    assert codes == [200, 200, 429, 429]


def test_missing_key_returns_503_with_a_clear_message(engine, settings, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    app = create_app(settings, engine)           # no injected client
    http = TestClient(app)
    token = http.post("/pair", json={"code": engine.pairing.create_code()}).json()["token"]
    r = http.post("/ai/tasks", json={"instruction": "hi"},
                  headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 503 and "ANTHROPIC_API_KEY" in r.json()["detail"]


def test_budget_exhausted_returns_503(engine, settings):
    settings.ai_daily_token_cap = 100
    http, auth, _ = build(engine, settings, [resp([text("a")], inp=90, out=20), resp([text("b")])])
    assert http.post("/ai/tasks", json={"instruction": "hi"}, headers=auth).status_code == 200
    r = http.post("/ai/tasks", json={"instruction": "again"}, headers=auth)
    assert r.status_code == 503 and "budget" in r.json()["detail"]


def test_emergency_stop_endpoint_stops_ai(engine, settings):
    http, auth, client = build(engine, settings, [resp([text("a")])])
    http.post("/emergency-stop", headers=auth)
    r = http.post("/ai/tasks", json={"instruction": "hi"}, headers=auth)
    assert r.status_code == 503 and client.calls == []
