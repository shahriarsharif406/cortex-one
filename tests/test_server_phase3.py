import threading
import time

from fastapi.testclient import TestClient

from agent import __version__
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use


def build(engine, settings, script, hook=None):
    client = FakeClient(script, hook=hook)
    app = create_app(settings, engine, ai_client=client)
    http = TestClient(app)

    def pair(name):
        code = engine.pairing.create_code()
        token = http.post("/pair", json={"code": code, "device_name": name}).json()["token"]
        return {"Authorization": f"Bearer {token}"}

    return http, pair, client


def wait_done(http, auth, job_id, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = http.get(f"/ai/tasks/{job_id}", headers=auth).json()
        if body["status"] != "running":
            return body
        time.sleep(0.02)
    raise AssertionError("job did not finish")


def ask_shutdown(http, auth, instruction="shut down"):
    r = http.post("/ai/tasks", json={"instruction": instruction}, headers=auth)
    assert r.status_code == 200
    return r.json()["pending_confirmations"][0]


SHUTDOWN_SCRIPT = lambda: [resp([tool_use("t1", "shutdown")], "tool_use"), resp([text("waiting")])]  # noqa: E731


# ---------------------------------------------------------------- health / cors
def test_health_has_version_and_nothing_else(engine, settings):
    http, _, _ = build(engine, settings, [])
    assert http.get("/health").json() == {"status": "ok", "version": __version__}


def test_cors_is_off(engine, settings):
    http, pair, _ = build(engine, settings, [])
    auth = pair("phone")
    for headers in ({"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"},
                    {"Origin": "https://evil.example", **auth}):
        for method in ("options", "get"):
            r = getattr(http, method)("/ai/pending", headers=headers)
            assert not any(h.lower().startswith("access-control-") for h in r.headers)
    assert http.options("/health", headers={"Origin": "https://evil.example"}).status_code == 405


# --------------------------------------------------------------------- pending
def test_pending_requires_auth(engine, settings):
    http, _, _ = build(engine, settings, [])
    assert http.get("/ai/pending").status_code == 401
    assert http.post("/ai/confirm", json={"confirm_token": "x"}).status_code == 401
    assert http.post("/ai/cancel", json={"confirm_token": "x"}).status_code == 401
    assert http.get("/ai/tasks/abc").status_code == 401


def test_pending_lists_ai_requests_with_description_and_countdown(engine, settings, runner):
    http, pair, _ = build(engine, settings, [
        resp([tool_use("t1", "run_script", name="backup"), tool_use("t2", "restart")], "tool_use"),
        resp([text("waiting")])])
    auth = pair("phone")
    assert http.get("/ai/pending", headers=auth).json() == []
    http.post("/ai/tasks", json={"instruction": "backup then restart"}, headers=auth)
    rows = http.get("/ai/pending", headers=auth).json()
    assert runner.calls == []
    by_action = {r["action"]: r for r in rows}
    assert set(by_action) == {"run_script", "restart"}
    script = by_action["run_script"]
    assert script["params"] == {"name": "backup"}
    assert script["command"] == ["powershell", "-File", "backup.ps1"]     # exactly what runs
    assert "backup" in script["summary"] and "30 seconds" in by_action["restart"]["summary"]
    assert 0 < script["expires_in"] <= settings.confirm_ttl_seconds and script["confirm_token"]


def test_pending_is_per_device_and_excludes_plain_http_confirmations(engine, settings):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    phone, other = pair("phone"), pair("tablet")
    # a confirmation started over plain HTTP is not an "AI request"
    http.post("/actions/restart", json={}, headers=phone)
    assert http.get("/ai/pending", headers=phone).json() == []
    ask_shutdown(http, phone)
    assert [r["action"] for r in http.get("/ai/pending", headers=phone).json()] == ["shutdown"]
    assert http.get("/ai/pending", headers=other).json() == []


def test_pending_entries_expire(engine, settings):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    auth = pair("phone")
    ask_shutdown(http, auth)
    clock = [time.monotonic() + settings.confirm_ttl_seconds + 1]
    engine.confirmations.now = lambda: clock[0]
    assert http.get("/ai/pending", headers=auth).json() == []


# --------------------------------------------------------------------- confirm
def test_confirm_runs_exactly_the_requested_action_once(engine, settings, runner):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    auth = pair("phone")
    p = ask_shutdown(http, auth)
    assert runner.calls == []
    r = http.post("/ai/confirm", json={"confirm_token": p["confirm_token"]}, headers=auth)
    assert r.status_code == 200 and r.json()["status"] == "ok" and r.json()["action"] == "shutdown"
    assert runner.calls == [["shutdown", "/s", "/t", "30"]]
    again = http.post("/ai/confirm", json={"confirm_token": p["confirm_token"]}, headers=auth)
    assert again.status_code == 403 and len(runner.calls) == 1              # single use
    assert http.get("/ai/pending", headers=auth).json() == []


def test_confirm_run_script_goes_through_the_allowlist(engine, settings, runner):
    http, pair, _ = build(engine, settings, [
        resp([tool_use("t1", "run_script", name="backup")], "tool_use"), resp([text("w")])])
    auth = pair("phone")
    p = ask_shutdown(http, auth, "backup")
    http.post("/ai/confirm", json={"confirm_token": p["confirm_token"]}, headers=auth)
    assert runner.calls == [["powershell", "-File", "backup.ps1"]]


def test_confirm_rejects_unknown_foreign_and_expired_tokens(engine, settings, runner):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    phone, other = pair("phone"), pair("tablet")
    p = ask_shutdown(http, phone)
    token = p["confirm_token"]
    assert http.post("/ai/confirm", json={"confirm_token": "nope"}, headers=phone).status_code == 403
    assert http.post("/ai/confirm", json={"confirm_token": token}, headers=other).status_code == 403
    assert runner.calls == []
    # a foreign attempt must not burn the owner's request
    assert [r["confirm_token"] for r in http.get("/ai/pending", headers=phone).json()] == [token]
    engine.confirmations.now = lambda t=time.monotonic() + settings.confirm_ttl_seconds + 1: t
    assert http.post("/ai/confirm", json={"confirm_token": token}, headers=phone).status_code == 403
    assert runner.calls == []                                              # expired


def test_confirm_endpoint_cannot_redeem_plain_http_tokens(engine, settings, runner):
    http, pair, _ = build(engine, settings, [])
    auth = pair("phone")
    token = http.post("/actions/shutdown", json={}, headers=auth).json()["confirm_token"]
    r = http.post("/ai/confirm", json={"confirm_token": token}, headers=auth)
    assert r.status_code == 403 and runner.calls == []
    # but the normal flow still works with it
    assert http.post("/actions/shutdown", json={"confirm_token": token}, headers=auth).status_code == 200


def test_confirm_validation_and_audit(engine, settings):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    auth = pair("phone")
    assert http.post("/ai/confirm", json={}, headers=auth).status_code == 422
    assert http.post("/ai/confirm", json={"confirm_token": "x" * 65}, headers=auth).status_code == 422
    p = ask_shutdown(http, auth)
    http.post("/ai/confirm", json={"confirm_token": p["confirm_token"]}, headers=auth)
    log = engine.audit.recent(10)
    assert any(r["action"] == "shutdown" and r["via"] == "http" and r["status"] == "ok" for r in log)
    assert p["confirm_token"] not in str(log)                              # token never stored


def test_cancel_discards_a_pending_request(engine, settings, runner):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    phone, other = pair("phone"), pair("tablet")
    p = ask_shutdown(http, phone)
    assert http.post("/ai/cancel", json={"confirm_token": p["confirm_token"]},
                     headers=other).status_code == 404                     # not theirs
    assert http.post("/ai/cancel", json={"confirm_token": p["confirm_token"]},
                     headers=phone).json() == {"status": "cancelled"}
    assert http.post("/ai/confirm", json={"confirm_token": p["confirm_token"]},
                     headers=phone).status_code == 403
    assert runner.calls == []


# ------------------------------------------------------------------- job model
def test_async_task_returns_immediately_and_can_be_polled(engine, settings, files):
    http, pair, _ = build(engine, settings, [
        resp([tool_use("t1", "list_files", path=str(files))], "tool_use"),
        resp([text("২টি আইটেম")])])
    auth = pair("phone")
    r = http.post("/ai/tasks", json={"instruction": "list", "wait": False}, headers=auth)
    assert r.status_code == 202 and r.json()["status"] == "running" and r.json()["id"]
    body = wait_done(http, auth, r.json()["id"])
    assert body["status"] == "ok" and body["reply"] == "২টি আইটেম"
    assert body["steps"][0]["tool"] == "list_files" and body["id"] == r.json()["id"]
    assert body["tokens_used"] == 240


def test_async_task_shows_progress_and_enforces_one_at_a_time(engine, settings, files):
    started, release = threading.Event(), threading.Event()

    def slow(kwargs):
        started.set()
        assert release.wait(5)
        return resp([text("late")])

    http, pair, client = build(engine, settings, [
        resp([tool_use("t1", "list_files", path=str(files))], "tool_use"), slow,
        resp([text("never used")])])
    auth = pair("phone")
    job = http.post("/ai/tasks", json={"instruction": "a", "wait": False}, headers=auth).json()
    assert started.wait(5)
    running = http.get(f"/ai/tasks/{job['id']}", headers=auth).json()
    assert running["status"] == "running" and running["steps"][0]["tool"] == "list_files"
    second = http.post("/ai/tasks", json={"instruction": "b", "wait": False}, headers=auth)
    assert second.status_code == 503 and "already running" in second.json()["detail"]
    assert http.post("/ai/tasks", json={"instruction": "c"}, headers=auth).status_code == 503
    release.set()
    assert wait_done(http, auth, job["id"])["reply"] == "late"
    assert len(client.calls) == 2                                          # the others never called the API


def test_async_pending_confirmations_are_visible_in_the_job(engine, settings, runner):
    http, pair, _ = build(engine, settings, SHUTDOWN_SCRIPT())
    auth = pair("phone")
    job = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=auth).json()
    body = wait_done(http, auth, job["id"])
    assert body["pending_confirmations"][0]["action"] == "shutdown" and runner.calls == []


def test_jobs_are_private_to_their_device(engine, settings):
    http, pair, _ = build(engine, settings, [resp([text("a")])])
    phone, other = pair("phone"), pair("tablet")
    job = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=phone).json()
    wait_done(http, phone, job["id"])
    assert http.get(f"/ai/tasks/{job['id']}", headers=other).status_code == 404
    assert http.get("/ai/tasks/does-not-exist", headers=phone).status_code == 404


def test_async_start_failures_are_reported_immediately(engine, settings):
    http, pair, client = build(engine, settings, [resp([text("x")])])
    auth = pair("phone")
    assert http.post("/ai/tasks", json={"instruction": "x" * 2001, "wait": False},
                     headers=auth).status_code == 422
    settings.ai_daily_token_cap = 0
    r = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=auth)
    assert r.status_code == 503 and "budget" in r.json()["detail"] and client.calls == []
    settings.ai_daily_token_cap = 200_000
    http.post("/emergency-stop", headers=auth)
    r = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=auth)
    assert r.status_code == 503 and client.calls == []


def test_async_step_cap_still_applies(engine, settings, files):
    settings.ai_max_steps = 2
    loop = [resp([tool_use(f"t{i}", "list_files", path=str(files))], "tool_use") for i in range(5)]
    http, pair, client = build(engine, settings, loop)
    auth = pair("phone")
    job = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=auth).json()
    body = wait_done(http, auth, job["id"])
    assert body["status"] == "stopped" and "Step limit" in body["stopped_reason"]
    assert len(client.calls) == 2


def test_emergency_stop_halts_a_running_async_task(engine, settings, files):
    gate = threading.Event()

    def stop_now(kwargs):
        engine.ctx.stop_event.set()
        gate.set()
        return resp([tool_use("t2", "list_files", path=str(files))], "tool_use")

    http, pair, client = build(engine, settings, [
        resp([tool_use("t1", "list_files", path=str(files))], "tool_use"), stop_now,
        resp([text("must not be reached")])])
    auth = pair("phone")
    job = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=auth).json()
    body = wait_done(http, auth, job["id"])
    assert body["status"] == "stopped" and "emergency" in body["stopped_reason"].lower()
    assert len(client.calls) == 2


def test_unexpected_crash_in_a_job_becomes_a_clean_error(engine, settings, monkeypatch):
    http, pair, _ = build(engine, settings, [resp([text("x")])])
    auth = pair("phone")
    import agent.ai as ai_module
    monkeypatch.setattr(ai_module.Orchestrator, "_loop",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("secret detail sk-ant-XYZ")))
    job = http.post("/ai/tasks", json={"instruction": "x", "wait": False}, headers=auth).json()
    body = wait_done(http, auth, job["id"])
    assert body["status"] == "error" and "sk-ant" not in str(body) and "secret detail" not in str(body)
    # the lock was released, so a new task can start
    monkeypatch.undo()
    assert http.post("/ai/tasks", json={"instruction": "y"}, headers=auth).status_code in (200, 503)
    assert not engine.ctx.stop_event.is_set()


def test_old_synchronous_behaviour_is_unchanged(engine, settings):
    http, pair, _ = build(engine, settings, [resp([text("hi")])])
    body = http.post("/ai/tasks", json={"instruction": "x"}, headers=pair("phone")).json()
    assert body["status"] == "ok" and body["reply"] == "hi" and "id" not in body


# --------------------------------------------------------------- capabilities
def test_capabilities_needs_auth_and_leaks_no_secrets(engine, settings):
    http, pair, _ = build(engine, settings, [])
    assert http.get("/capabilities").status_code == 401
    body = http.get("/capabilities", headers=pair("phone")).json()
    assert body["allowed_roots"] == [str(settings.allowed_roots[0])]
    assert body["allowed_apps"] == ["notepad"] and body["log_names"] == ["coder"]
    assert body["allowed_domains"] == ["docs.example.org", "example.com"]
    dump = str(body)
    assert "pbkdf2" not in dump and "backup.ps1" not in dump and "gw-secret" not in dump


def test_ai_is_told_the_allowlists_but_not_secrets(engine, settings, files):
    http, pair, client = build(engine, settings, [resp([text("hi")])])
    http.post("/ai/tasks", json={"instruction": "x"}, headers=pair("phone"))
    system = client.calls[0]["system"]
    assert str(files) in system and "notepad" in system and "coder" in system
    assert "pbkdf2" not in system and "backup.ps1" not in system
