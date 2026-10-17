import pytest
from fastapi.testclient import TestClient

from agent.server import create_app


@pytest.fixture
def client(engine, settings):
    return TestClient(create_app(settings, engine))


@pytest.fixture
def auth(client, engine):
    code = engine.pairing.create_code()
    r = client.post("/pair", json={"code": code, "device_name": "phone"})
    assert r.status_code == 200
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_health_open_but_minimal(client):
    from agent import __version__
    body = client.get("/health").json()
    assert body["status"] == "ok" and body["version"] == __version__
    # names and coarse numbers only: no token, path, mac or config value
    assert set(body) == {"status", "version", "computer_id", "computer_name", "uptime_seconds",
                         "battery", "link", "network"}   # no last_power_request for strangers


def test_docs_and_schema_hidden(client):
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404


def test_protected_routes_need_a_valid_token(client):
    assert client.get("/actions").status_code == 401
    assert client.post("/actions/status", json={}).status_code == 401
    assert client.get("/audit").status_code == 401
    bad = {"Authorization": "Bearer nope"}
    assert client.get("/actions", headers=bad).status_code == 401
    assert client.get("/actions", headers={"Authorization": "Basic abc"}).status_code == 401


def test_pair_rejects_bad_code_and_locks(client, engine):
    code = engine.pairing.create_code()
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(engine.settings.max_pair_failures):
        assert client.post("/pair", json={"code": wrong}).status_code == 403
    assert client.post("/pair", json={"code": code}).status_code == 429


def test_pair_validates_shape(client):
    assert client.post("/pair", json={"code": "12"}).status_code == 422
    assert client.post("/pair", json={"code": "abcdef"}).status_code == 422


def test_low_risk_action_runs_immediately(client, auth):
    r = client.post("/actions/status", json={}, headers=auth)
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_high_risk_needs_confirmation(client, auth, runner):
    r = client.post("/actions/shutdown", json={}, headers=auth)
    body = r.json()
    assert body["status"] == "confirmation_required" and runner.calls == []
    r = client.post("/actions/shutdown", json={"confirm_token": body["confirm_token"]},
                    headers=auth)
    assert r.json()["status"] == "ok"
    assert runner.calls == [["shutdown", "/s", "/t", "30"]]


def test_confirmation_cannot_be_replayed_or_swapped(client, auth, runner):
    token = client.post("/actions/shutdown", json={}, headers=auth).json()["confirm_token"]
    # wrong action
    r = client.post("/actions/restart", json={"confirm_token": token}, headers=auth)
    assert r.status_code == 403
    # token was consumed by the failed attempt: cannot be reused
    r = client.post("/actions/shutdown", json={"confirm_token": token}, headers=auth)
    assert r.status_code == 403 and runner.calls == []


def test_confirmation_bound_to_script_name(client, auth, runner, settings):
    settings.approved_scripts["other"] = ["x"]
    token = client.post("/actions/run_script", json={"params": {"name": "backup"}},
                        headers=auth).json()["confirm_token"]
    r = client.post("/actions/run_script",
                    json={"params": {"name": "other"}, "confirm_token": token},
                    headers=auth)
    assert r.status_code == 403 and runner.calls == []


def test_unknown_action_404_and_denied_path_reported(client, auth, files):
    assert client.post("/actions/format_disk", json={}, headers=auth).status_code == 404
    r = client.post("/actions/list_files", json={"params": {"path": "/etc"}}, headers=auth)
    assert r.json()["status"] == "failed" and "outside" in r.json()["message"]


def test_rate_limit(client, auth, engine):
    engine.limiter.limit = 3
    codes = [client.get("/actions", headers=auth).status_code for _ in range(5)]
    assert codes == [200, 200, 200, 429, 429]


def test_revoked_device_loses_access(client, auth, engine):
    device = engine.pairing.list_devices()[0]
    engine.pairing.revoke(device["id"])
    assert client.get("/actions", headers=auth).status_code == 401


def test_emergency_stop_endpoint(client, auth, engine):
    r = client.post("/emergency-stop", headers=auth)
    assert r.status_code == 200 and engine.ctx.stop_event.is_set()


def test_audit_endpoint_shows_actions(client, auth):
    client.post("/actions/status", json={}, headers=auth)
    rows = client.get("/audit?limit=5", headers=auth).json()
    assert any(r["action"] == "status" for r in rows)


def test_sms_inbound_requires_gateway_secret(client, runner):
    body = {"from": "01711111111", "text": "SHUTDOWN 4821"}
    assert client.post("/sms/inbound", json=body).status_code == 401
    r = client.post("/sms/inbound", json=body, headers={"X-Gateway-Secret": "wrong"})
    assert r.status_code == 401 and runner.calls == []


def test_sms_inbound_end_to_end(client, runner):
    r = client.post("/sms/inbound",
                    json={"from": "01711111111", "text": "SHUTDOWN 4821"},
                    headers={"X-Gateway-Secret": "gw-secret"})
    assert r.status_code == 200 and "Shutting down" in r.json()["reply"]
    assert runner.calls == [["shutdown", "/s", "/t", "30"]]


def test_sms_inbound_disabled_without_gateway_secret(client, settings):
    settings.gateway_secret_hash = ""
    r = client.post("/sms/inbound", json={"from": "01711111111", "text": "STATUS 4821"},
                    headers={"X-Gateway-Secret": "gw-secret"})
    assert r.status_code == 401
