import json
import urllib.request

import pytest
from fastapi.testclient import TestClient

from agent import notify
from agent.notify import Notifier
from agent.power import Battery, PowerWatcher
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use


class FakeBattery:
    def __init__(self, *seq):
        self.seq = list(seq)
        self.now = None

    def set(self, percent, plugged):
        self.now = Battery(percent, plugged)

    def __call__(self):
        return self.now


class FakeNotifier:
    def __init__(self):
        self.sent = []

    def notify(self, event, pct, when):
        self.sent.append((event, pct))
        return True


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def make(engine, notifier=None):
    bat, clock = FakeBattery(), Clock()
    return PowerWatcher(engine, bat, notifier, clock), bat, clock


# ------------------------------------------------------------- transitions
def test_ac_lost_and_restored_are_recorded(engine):
    w, bat, _ = make(engine)
    bat.set(80, True)
    assert w.tick() == []
    bat.set(79, False)
    assert w.tick() == ["ac_lost"]
    bat.set(79, True)
    assert w.tick() == ["ac_restored"]
    kinds = [a["kind"] for a in engine.alerts.recent()]
    assert kinds == ["ac_restored", "ac_lost"]
    assert any(r["via"] == "power" and r["action"] == "ac_lost" for r in engine.audit.recent(10))


def test_warn_and_critical_fire_once_each(engine):
    w, bat, _ = make(engine)
    bat.set(50, False); assert w.tick() == []
    bat.set(30, False); assert w.tick() == ["battery_warn"]
    bat.set(29, False); assert w.tick() == []
    bat.set(10, False); assert w.tick() == ["battery_critical"]
    bat.set(9, False); assert w.tick() == []


def test_jump_straight_to_critical(engine):
    w, bat, _ = make(engine)
    bat.set(60, False); w.tick()
    bat.set(5, False)
    assert w.tick() == ["battery_critical"]


def test_flapping_around_threshold_does_not_spam(engine):
    w, bat, _ = make(engine)
    bat.set(31, False); w.tick()
    seen = []
    for pct in (30, 31, 30, 32, 29, 31, 30):
        bat.set(pct, False)
        seen += w.tick()
    assert seen == ["battery_warn"]               # hysteresis: only the first crossing


def test_recovery_rearms_alerts(engine):
    w, bat, _ = make(engine)
    bat.set(25, False); assert w.tick() == ["battery_warn"]
    bat.set(60, True); assert w.tick() == ["ac_restored"]
    bat.set(25, False)
    assert w.tick() == ["ac_lost", "battery_warn"]


def test_flapping_power_pushes_are_rate_limited(engine):
    note = FakeNotifier()
    w, bat, clock = make(engine, note)
    bat.set(80, True); w.tick()
    for _ in range(5):
        bat.set(80, False); w.tick()
        bat.set(80, True); w.tick()
        clock.t += 10
    assert [e for e, _ in note.sent].count("Power cut: running on battery") == 1
    clock.t += 500
    bat.set(80, False); w.tick()
    assert [e for e, _ in note.sent].count("Power cut: running on battery") == 2
    assert len(engine.alerts.recent(100)) == 11   # every transition is still recorded


def test_no_battery_desktop_is_idle(engine):
    w, bat, _ = make(engine)
    bat.now = None
    assert w.tick() == [] and w.tick() == []
    assert engine.alerts.recent() == []


def test_unknown_plug_state_never_raises_or_acts(engine, runner, settings):
    settings.critical_action = "hibernate"
    w, bat, _ = make(engine)
    bat.set(3, None)
    assert w.tick() == []
    assert runner.calls == []


def test_provider_crash_is_swallowed(engine):
    w, _, _ = make(engine)
    w.provider = lambda: 1 / 0
    assert w.tick() == []


def test_alert_table_is_capped(engine):
    for i in range(260):
        engine.alerts.add("battery_warn", 20, False, f"m{i}")
    assert len(engine.alerts.recent(100)) == 100
    with engine.db.conn() as c:
        assert c.execute("SELECT COUNT(*) FROM alerts").fetchone()[0] <= 201


# ------------------------------------------------------------- critical action
def test_default_critical_action_is_none(engine, runner):
    w, bat, _ = make(engine)
    bat.set(50, False); w.tick()
    bat.set(5, False); w.tick()
    assert runner.calls == []


def test_critical_hibernate_runs_once_through_the_engine(engine, runner, settings):
    settings.critical_action = "hibernate"
    w, bat, _ = make(engine)
    bat.set(50, False); w.tick()
    bat.set(9, False); w.tick()
    assert runner.calls == [["shutdown", "/h"]]
    bat.set(8, False); w.tick(); w.tick()
    assert runner.calls == [["shutdown", "/h"]]    # not repeated
    rows = [r for r in engine.audit.recent(20) if r["action"] == "hibernate"]
    assert rows and rows[0]["via"] == "watcher" and rows[0]["status"] == "ok"


def test_critical_lock(engine, runner, settings):
    settings.critical_action = "lock"
    w, bat, _ = make(engine)
    bat.set(50, False); w.tick(); bat.set(9, False); w.tick()
    assert runner.calls == [["rundll32.exe", "user32.dll,LockWorkStation"]]


@pytest.mark.parametrize("value", ["shutdown", "restart", "run_script", "SHUTDOWN", "", None, "hibernate;x"])
def test_shutdown_and_junk_are_never_executed_by_the_watcher(engine, runner, settings, value):
    settings.critical_action = value
    w, bat, _ = make(engine)
    bat.set(50, False); w.tick(); bat.set(5, False); w.tick()
    assert runner.calls == []


def test_no_action_while_plugged_in_even_at_critical(engine, runner, settings):
    settings.critical_action = "hibernate"
    assert engine.run_power_action(5, True) is None
    assert engine.run_power_action(5, None) is None
    assert engine.run_power_action(50, False) is None      # above critical
    assert engine.run_power_action("5", False) is None
    assert engine.run_power_action(None, False) is None
    assert runner.calls == []


def test_watcher_channel_is_reserved(engine, runner):
    r = engine.run("hibernate", {}, actor="evil", via="watcher")
    assert not r.ok and runner.calls == []


def test_hibernate_over_http_still_needs_confirmation(engine, settings, runner):
    settings.critical_action = "hibernate"
    http = TestClient(create_app(settings, engine))
    code = engine.pairing.create_code()
    tok = http.post("/pair", json={"code": code, "device_name": "p"}).json()["token"]
    auth = {"Authorization": f"Bearer {tok}"}
    r = http.post("/actions/hibernate", json={"params": {}}, headers=auth).json()
    assert r["status"] == "confirmation_required" and runner.calls == []
    bad = http.post("/actions/hibernate", json={"params": {}, "confirm_token": "x" * 10}, headers=auth)
    assert bad.status_code == 403 and runner.calls == []
    # there is no HTTP/body field that selects the watcher channel
    http.post("/actions/hibernate", json={"params": {"via": "watcher"}}, headers=auth)
    assert runner.calls == []


def test_ai_cannot_hibernate_only_request(engine, settings, runner):
    from agent.ai import Orchestrator
    settings.critical_action = "hibernate"
    client = FakeClient([resp([tool_use("t1", "hibernate")], "tool_use"), resp([text("waiting")])])
    orc = Orchestrator(engine, client=client, today=lambda: "2026-10-13")
    r = orc.run("hibernate", device_id=1, device_name="phone")
    assert runner.calls == []
    assert [p["action"] for p in r.pending_confirmations] == ["hibernate"]


def test_sms_cannot_hibernate(engine, runner):
    from agent.sms import COMMANDS, SmsHandler
    assert "hibernate" not in COMMANDS.values() and "HIBERNATE" not in COMMANDS
    h = SmsHandler(engine)
    h.handle("+8801711111111", "HIBERNATE 4821")
    assert runner.calls == []


def test_hibernate_is_high_risk_in_registry():
    from agent.actions import REGISTRY
    assert REGISTRY["hibernate"].risk == "high"


# ------------------------------------------------------------- /alerts
def test_alerts_endpoint(engine, settings):
    http = TestClient(create_app(settings, engine))
    assert http.get("/alerts").status_code == 401
    code = engine.pairing.create_code()
    tok = http.post("/pair", json={"code": code, "device_name": "p"}).json()["token"]
    auth = {"Authorization": f"Bearer {tok}"}
    engine.alerts.add("ac_lost", 77, False, "Power cut: running on battery (77%)")
    body = http.get("/alerts?limit=5", headers=auth).json()
    assert body[0]["kind"] == "ac_lost" and body[0]["battery_percent"] == 77
    assert body[0]["plugged"] is False


# ------------------------------------------------------------- notifier
def settings_for(settings, kind, target):
    settings.notifier_type, settings.notifier_target = kind, target
    return settings


def test_notifier_is_off_by_default(settings):
    assert Notifier.from_settings(settings, env={}) is None


@pytest.mark.parametrize("kind,target", [
    ("ntfy", "ab"), ("ntfy", "has space topic"), ("ntfy", "../x"),
    ("webhook", "http://insecure.example/x"), ("webhook", "https://user:pw@h.example/x"),
    ("webhook", "ftp://h.example"), ("webhook", "https://h.example:8443/x"), ("pigeon", "abcdefgh")])
def test_bad_notifier_config_disables_it(settings, kind, target):
    assert Notifier.from_settings(settings_for(settings, kind, target), env={}) is None


def test_ntfy_message_is_short_and_secret_free(settings):
    sent = []
    n = Notifier.from_settings(settings_for(settings, "ntfy", "my-secret-topic-1"), env={},
                               send=sent.append)
    assert n.notify("Power cut: running on battery", 54, "14:32")
    req = sent[0]
    assert req.full_url == "https://ntfy.sh/my-secret-topic-1"
    body = req.data.decode()
    assert body == "Cortex One: Power cut: running on battery, battery 54%, 14:32"


def test_webhook_payload(settings):
    sent = []
    n = Notifier.from_settings(settings_for(settings, "webhook", "https://hooks.example.com/abc123"),
                               env={}, send=sent.append)
    n.notify("Battery critical", 9, "03:10")
    payload = json.loads(sent[0].data)
    assert set(payload) == {"event", "battery_percent", "time", "text"}
    assert "abc123" not in sent[0].data.decode()


def test_env_target_overrides_config(settings):
    n = Notifier.from_settings(settings_for(settings, "ntfy", "from-config-topic-01"),
                               env={notify.ENV_TARGET: "from-env-topic-0123456"}, send=lambda r: None)
    assert n.target == "from-env-topic-0123456"


def test_notifier_failure_is_silent_and_never_logs_the_target(settings, caplog):
    def boom(req):
        raise OSError("down https://hooks.example.com/abc123")
    n = Notifier("webhook", "https://hooks.example.com/abc123", boom)
    with caplog.at_level("DEBUG"):
        assert n.notify("x", 5, "00:00") is False
    log = caplog.text
    assert "abc123" not in log and "hooks.example.com/***" in log


def test_watcher_survives_a_raising_notifier(engine):
    class Bad:
        def notify(self, *a):
            raise RuntimeError("boom")
    w, bat, _ = make(engine, Bad())
    bat.set(80, True); w.tick(); bat.set(80, False)
    assert w.tick() == ["ac_lost"]


def test_no_redirects_followed():
    h = notify._NoRedirect()
    req = urllib.request.Request("https://a.example/")
    assert h.redirect_request(req, None, 302, "Found", {}, "https://evil.example/") is None
