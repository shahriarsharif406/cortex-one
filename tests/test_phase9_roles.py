"""Session 2, phase 9: device roles (owner / viewer) and token hygiene."""
import sqlite3
import time

import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from agent.actions import REGISTRY
from agent.config import Settings
from agent.db import Database
from agent.main import main
from agent.security import VIEWER_ACTIONS, ROLES
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use


@pytest.fixture
def app(engine, settings):
    return create_app(settings, engine, ai_client=FakeClient([resp([text("hi")])] * 20))


@pytest.fixture
def http(app):
    return TestClient(app)


def pair(http, engine, role="owner", name="phone"):
    code = engine.pairing.create_code(role)
    body = http.post("/pair", json={"code": code, "device_name": name}).json()
    return {"Authorization": f"Bearer {body['token']}"}, body


@pytest.fixture
def owner(http, engine):
    return pair(http, engine, "owner", "owner-phone")[0]


@pytest.fixture
def viewer(http, engine):
    return pair(http, engine, "viewer", "family-phone")[0]


# ------------------------------------------------------------------ pairing
def test_roles_are_exactly_two():
    assert ROLES == ("owner", "viewer")


def test_pair_returns_the_role_chosen_when_the_code_was_made(http, engine):
    assert pair(http, engine, "viewer")[1]["role"] == "viewer"
    assert pair(http, engine, "owner")[1]["role"] == "owner"
    assert pair(http, engine)[1]["role"] == "owner"        # the default


def test_an_unknown_role_cannot_be_chosen(engine):
    for bad in ("admin", "", "OWNER", None, "owner;viewer"):
        with pytest.raises(ValueError):
            engine.pairing.create_code(bad)


def test_the_phone_cannot_ask_for_a_role(http, engine):
    code = engine.pairing.create_code("viewer")
    r = http.post("/pair", json={"code": code, "device_name": "p", "role": "owner"})
    assert r.status_code == 200 and r.json()["role"] == "viewer"


def test_a_new_code_replaces_an_unused_one_with_its_own_role(http, engine):
    engine.pairing.create_code("owner")
    code = engine.pairing.create_code("viewer")
    assert http.post("/pair", json={"code": code}).json()["role"] == "viewer"


def test_me_reports_name_and_role_without_secrets(http, engine):
    h, _ = pair(http, engine, "viewer", "kitchen")
    body = http.get("/me", headers=h).json()
    assert body == {"name": "kitchen", "role": "viewer"}
    assert http.get("/me").status_code == 401


def test_cli_pair_with_a_role(engine, settings, capsys):
    assert main(["--data-dir", str(settings.data_dir), "pair", "--role", "viewer"]) == 0
    out = capsys.readouterr().out
    assert "role: viewer" in out and "can only look" in out
    assert main(["--data-dir", str(settings.data_dir), "pair"]) == 0
    assert "role: owner" in capsys.readouterr().out


# ------------------------------------------------------- every route, both roles
PUBLIC = {("GET", "/health"), ("POST", "/pair"), ("POST", "/sms/inbound")}
# (method, path) -> may a VIEWER use it?
ROUTES = {
    ("GET", "/me"): True, ("GET", "/actions"): True, ("POST", "/actions/{name}"): True,
    ("GET", "/screenshots"): True, ("GET", "/screenshots/{name}"): True, ("GET", "/alerts"): True,
    ("GET", "/watch"): True, ("GET", "/network"): True, ("GET", "/ai/history"): True,
    ("POST", "/emergency-stop"): False, ("POST", "/ai/tasks"): False, ("GET", "/ai/tasks/{job_id}"): False,
    ("GET", "/capabilities"): False, ("GET", "/ai/pending"): False, ("POST", "/ai/confirm"): False,
    ("POST", "/ai/cancel"): False, ("GET", "/ai/usage"): False, ("GET", "/gui/session"): False,
    ("GET", "/gui/shot/{name}"): False, ("GET", "/audit"): False,
}


def real_routes(app):
    out = set()
    for r in app.routes:
        if isinstance(r, APIRoute):
            for m in r.methods - {"HEAD", "OPTIONS"}:
                out.add((m, r.path))
    return out


def test_every_route_has_an_explicit_role_decision(app):
    """A new endpoint fails this test until someone decides whether a viewer may use it."""
    assert real_routes(app) - PUBLIC == set(ROUTES)


BODIES = {"/ai/tasks": {"instruction": "hello"}, "/ai/confirm": {"confirm_token": "x" * 10},
          "/ai/cancel": {"confirm_token": "x" * 10}, "/actions/{name}": {"params": {}}}


def call(http, method, path, headers):
    url = (path.replace("{name}", "screenshot-20260101-000000.png" if "screenshots" in path or "gui" in path
                        else "status").replace("{job_id}", "nothing"))
    kw = {"json": BODIES[path]} if path in BODIES else {}
    return http.request(method, url, headers=headers, **kw)


@pytest.mark.parametrize("route", sorted(ROUTES))
def test_viewer_access_matches_the_matrix(http, owner, viewer, route):
    method, path = route
    allowed = ROUTES[route]
    v = call(http, method, path, viewer)
    if allowed:
        assert v.status_code != 401 and not (v.status_code == 403 and "viewer role" in v.text), (route, v.status_code)
    else:
        assert v.status_code == 403, (route, v.status_code)
        assert "viewer role" in v.text
    o = call(http, method, path, owner)
    # an owner may still get a 403 for a bad confirmation token, but never a role refusal
    assert o.status_code != 401 and not (o.status_code == 403 and "viewer role" in o.text), (route, o.status_code)
    assert call(http, method, path, {}).status_code == 401


def test_denied_viewer_requests_are_audited(http, engine, viewer):
    http.get("/audit", headers=viewer)
    rows = [r for r in engine.audit.recent(10) if r["status"] == "rejected" and r["detail"] == "viewer role"]
    assert rows and rows[0]["actor"] == "device:family-phone"


# --------------------------------------------------------- every action, both roles
@pytest.mark.parametrize("name", sorted(REGISTRY))
def test_every_action_against_both_roles(http, engine, runner, launched, opened, owner, viewer, name):
    spec = REGISTRY[name]
    params = {k: "x" for k in spec.params}
    rv = http.post(f"/actions/{name}", json={"params": params}, headers=viewer)
    if name in VIEWER_ACTIONS:
        assert spec.risk == "low"                                   # a viewer never gets a high-risk action
        assert not (rv.status_code == 403 and "viewer role" in rv.text)
    else:
        assert rv.status_code == 403
        assert runner.calls == [] and launched == [] and opened == []
        assert [r for r in engine.audit.recent(5) if r["action"] == name and r["detail"] == "viewer role"]
    ro = http.post(f"/actions/{name}", json={"params": params}, headers=owner)
    assert not (ro.status_code == 403 and "viewer role" in ro.text) and ro.status_code != 401
    if spec.risk == "high" and ro.status_code == 200:
        assert ro.json()["status"] == "confirmation_required"


def test_viewer_actions_are_exactly_the_short_read_only_list():
    assert VIEWER_ACTIONS == {"status", "system_info", "list_processes", "take_screenshot"}
    assert all(REGISTRY[n].risk == "low" for n in VIEWER_ACTIONS)
    for n in ("shutdown", "restart", "hibernate", "sleep", "lock", "run_script", "open_app", "open_url",
              "list_files", "find_files", "copy_file", "make_folder", "tail_log", "wake_computer",
              "emergency_stop", "cancel_shutdown", "gui_session_start", "coding_session_start"):
        assert n not in VIEWER_ACTIONS


@pytest.mark.parametrize("name", sorted(REGISTRY))
def test_engine_refuses_viewer_actions_as_a_second_layer(engine, runner, launched, opened, name):
    params = {k: "x" for k in REGISTRY[name].params}
    r = engine.run(name, params, actor="device:v", via="http", role="viewer")
    if name not in VIEWER_ACTIONS:
        assert not r.ok and "viewer" in r.message.lower()
        assert runner.calls == [] and launched == [] and opened == []


def test_viewer_cannot_make_a_confirmation_or_use_an_owners_token(http, engine, runner, owner, viewer):
    r = http.post("/actions/shutdown", json={}, headers=viewer)
    assert r.status_code == 403 and engine.confirmations._pending == {}
    tok = http.post("/actions/shutdown", json={}, headers=owner).json()["confirm_token"]
    stolen = http.post("/actions/shutdown", json={"confirm_token": tok}, headers=viewer)
    assert stolen.status_code == 403 and runner.calls == []
    assert http.post("/ai/confirm", json={"confirm_token": tok}, headers=viewer).status_code == 403


def test_viewer_actions_list_is_filtered(http, owner, viewer):
    names_v = {a["name"] for a in http.get("/actions", headers=viewer).json()}
    names_o = {a["name"] for a in http.get("/actions", headers=owner).json()}
    assert names_v == set(VIEWER_ACTIONS) and names_o == set(REGISTRY)


def test_viewer_can_look(http, engine, viewer):
    assert http.post("/actions/status", json={}, headers=viewer).json()["status"] == "ok"
    assert http.get("/alerts", headers=viewer).status_code == 200
    assert http.get("/screenshots", headers=viewer).status_code == 200
    assert http.get("/ai/history", headers=viewer).json() == []


def test_a_viewer_cannot_use_the_ai_at_all(http, engine, viewer, runner):
    assert http.post("/ai/tasks", headers=viewer, json={"instruction": "shut down"}).status_code == 403
    assert http.post("/ai/tasks", headers=viewer, json={"instruction": "x", "wait": False}).status_code == 403
    assert runner.calls == [] and not engine.audit.recent(50) == []


def test_the_viewer_cannot_stop_the_owners_work(http, engine, viewer):
    assert http.post("/emergency-stop", headers=viewer).status_code == 403
    assert not engine.ctx.stop_event.is_set()


# ---------------------------------------------------------------- token expiry
def test_tokens_do_not_expire_by_default(http, engine, settings):
    h, _ = pair(http, engine)
    t0 = time.time()
    engine.pairing.now = lambda: t0 + 10 * 365 * 86400
    assert settings.token_ttl_days == 0
    assert http.get("/me", headers=h).status_code == 200


def test_tokens_expire_after_the_configured_days(http, engine, settings):
    settings.token_ttl_days = 2
    h, _ = pair(http, engine)
    t0 = time.time()
    engine.pairing.now = lambda: t0 + 2 * 86400 - 60
    assert http.get("/me", headers=h).status_code == 200
    engine.pairing.now = lambda: t0 + 2 * 86400 + 60
    assert http.get("/me", headers=h).status_code == 401
    assert http.post("/actions/status", json={}, headers=h).status_code == 401


@pytest.mark.parametrize("bad", [-5, True, "7", None, 1.5, 0])
def test_a_bad_ttl_value_means_no_expiry(http, engine, settings, bad):
    settings.token_ttl_days = bad
    h, _ = pair(http, engine)
    engine.pairing.now = lambda: time.time() + 3650 * 86400
    assert http.get("/me", headers=h).status_code == 200


def test_expiry_is_visible_in_the_devices_list(http, engine, settings, capsys):
    settings.token_ttl_days = 30
    settings.save()                               # the CLI is another process: it reads config.json
    pair(http, engine, "viewer", "cousin")
    assert main(["--data-dir", str(settings.data_dir), "devices"]) == 0
    out = capsys.readouterr().out
    assert "cousin" in out and "role viewer" in out and "token expires in" in out
    engine.pairing.now = lambda: time.time() + 31 * 86400
    rows = engine.pairing.list_devices()
    assert rows[0]["expired"] is True and rows[0]["role"] == "viewer"


# ------------------------------------------------------------------- revocation
def test_revoke_takes_effect_on_the_very_next_request(http, engine):
    h, _ = pair(http, engine, "owner", "lost-phone")
    assert http.get("/me", headers=h).status_code == 200
    dev = [d for d in engine.pairing.list_devices() if d["name"] == "lost-phone"][0]
    assert engine.pairing.revoke(dev["id"])
    for call_ in (lambda: http.get("/me", headers=h), lambda: http.post("/actions/status", json={}, headers=h),
                  lambda: http.post("/ai/tasks", headers=h, json={"instruction": "x"}),
                  lambda: http.post("/emergency-stop", headers=h)):
        assert call_().status_code == 401


def test_revoke_also_kills_a_pending_confirmation_in_practice(http, engine, runner):
    h, _ = pair(http, engine)
    tok = http.post("/actions/shutdown", json={}, headers=h).json()["confirm_token"]
    engine.pairing.revoke(engine.pairing.list_devices()[0]["id"])
    r = http.post("/actions/shutdown", json={"confirm_token": tok}, headers=h)
    assert r.status_code == 401 and runner.calls == []


def test_revoke_from_the_cli_works_while_the_server_runs(http, engine, settings, capsys):
    h, _ = pair(http, engine)
    assert main(["--data-dir", str(settings.data_dir), "revoke", "1"]) == 0
    assert http.get("/me", headers=h).status_code == 401


def test_revoking_one_phone_leaves_the_other(http, engine):
    a, _ = pair(http, engine, "owner", "a")
    b, _ = pair(http, engine, "viewer", "b")
    engine.pairing.revoke([d for d in engine.pairing.list_devices() if d["name"] == "a"][0]["id"])
    assert http.get("/me", headers=a).status_code == 401 and http.get("/me", headers=b).status_code == 200


# --------------------------------------------------------------------------- link
def test_the_link_a_phone_used_is_remembered(engine, settings):
    client = TestClient(create_app(settings, engine), base_url="http://127.0.0.1:8765")
    code = engine.pairing.create_code()
    tok = client.post("/pair", json={"code": code}).json()["token"]
    client.get("/me", headers={"Authorization": f"Bearer {tok}"})
    assert engine.pairing.list_devices()[0]["last_link"] == "loopback"


def test_devices_cli_shows_role_last_seen_and_link(http, engine, settings, capsys):
    h, _ = pair(http, engine, "viewer", "tablet")
    http.get("/me", headers=h)
    engine.pairing.touch_link(1, "tailscale")
    main(["--data-dir", str(settings.data_dir), "devices"])
    out = capsys.readouterr().out
    assert "role viewer" in out and "link tailscale" in out and "last seen" in out


def test_junk_link_values_are_not_stored(engine, http):
    pair(http, engine)
    engine.pairing.touch_link(1, "evil'; DROP TABLE devices; --")
    assert engine.pairing.list_devices()[0]["last_link"] in (None, "")


# ------------------------------------------------------------------- migration
def test_an_old_database_without_roles_still_works(tmp_path):
    path = tmp_path / "data" / "cortex.db"
    path.parent.mkdir(parents=True)
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE devices (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
                              created_at REAL NOT NULL, last_seen REAL, revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE pairing_codes (code_hash TEXT PRIMARY KEY, expires_at REAL NOT NULL, used INTEGER NOT NULL DEFAULT 0);
    """)
    import hashlib
    con.execute("INSERT INTO devices (name, token_hash, created_at) VALUES ('old', ?, ?)",
                (hashlib.sha256(b"oldtoken").hexdigest(), time.time()))
    con.commit()
    con.close()
    db = Database(path)
    from agent.security import PairingManager
    mgr = PairingManager(db, Settings(data_dir=tmp_path / "data"))
    dev = mgr.authenticate("oldtoken")
    assert dev is not None and dev.role == "owner"            # phones paired before roles stay owners
    code = mgr.create_code("viewer")
    assert mgr.pair_with_role(code, "new")[1] == "viewer"


def test_an_unknown_role_in_the_database_is_treated_as_a_viewer(engine, http):
    h, _ = pair(http, engine)
    with engine.db.conn() as c:
        c.execute("UPDATE devices SET role = 'superuser'")
    assert http.get("/me", headers=h).json()["role"] == "viewer"
    assert http.post("/actions/shutdown", json={}, headers=h).status_code == 403


def test_doctor_warns_about_tokens_that_never_expire(settings):
    from agent.doctor import run_checks

    lines = "\n".join(c.line() for c in run_checks(settings, env={}, startup_probe=lambda: None))
    assert "tokens never expire" in lines
    settings.token_ttl_days = 14
    lines = "\n".join(c.line() for c in run_checks(settings, env={}, startup_probe=lambda: None))
    assert "phone tokens expire after 14 day(s)" in lines


def test_secrets_never_appear_in_me_or_devices(http, engine, capsys, settings):
    h, body = pair(http, engine)
    token = body["token"]
    assert token not in http.get("/me", headers=h).text
    main(["--data-dir", str(settings.data_dir), "devices"])
    assert token not in capsys.readouterr().out
