"""Session 2, phase 6: coding sessions and the remote-desktop helper."""
import itertools
import sys
import threading
import time

import pytest
from fastapi.testclient import TestClient

from agent.actions import REGISTRY, ProcessManager
from agent.ai import AI_TOOL_EXCLUDE, Orchestrator, build_tools
from agent.doctor import run_checks
from agent.sessions import MAX_RUNNING, parse_projects, precheck_high
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use

PY = sys.executable
_pids = itertools.count(1000)


class FakePopen:
    """A stand-in for subprocess.Popen: nothing real is ever started."""

    made: list = []

    def __init__(self, cmd, **kwargs):
        self.cmd, self.kwargs = list(cmd), kwargs
        self.pid = next(_pids)
        self.code = None
        self.killed = False
        self._done = threading.Event()
        FakePopen.made.append(self)

    def poll(self):
        return self.code

    def wait(self, timeout=None):
        self._done.wait(timeout if timeout is not None else 5)
        return self.code

    def kill(self):
        self.killed = True
        self.finish(-9)

    def finish(self, code=0):
        self.code = code
        self._done.set()


@pytest.fixture(autouse=True)
def _reset():
    FakePopen.made = []
    yield
    for p in FakePopen.made:       # let any watcher thread end
        p.finish(-1) if p.code is None else None


@pytest.fixture
def proj(engine, settings, files, monkeypatch):
    settings.coding_projects = {
        "api": {"path": str(files), "argv": [PY, "-c", "print('hi')"]},
        "Docs": {"path": str(files / "sub"), "argv": [PY, "--version"]},
    }
    engine.ctx.popen = FakePopen
    monkeypatch.setattr(ProcessManager, "kill_tree", staticmethod(lambda proc: proc.kill()))  # fakes
    return engine


@pytest.fixture
def http(engine, settings):
    return TestClient(create_app(settings, engine))


@pytest.fixture
def auth(http, engine):
    code = engine.pairing.create_code()
    return {"Authorization": f"Bearer {http.post('/pair', json={'code': code}).json()['token']}"}


def run(engine, action, **params):
    return engine.run(action, params, actor="t", via="http")


def wait_for(cond, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return False


# ---------------------------------------------------------------------- config
def test_valid_projects_are_parsed(proj, settings):
    projects, problems = parse_projects(settings)
    assert set(projects) == {"api", "docs"} and problems == []
    assert projects["api"].argv[0] == PY


@pytest.mark.parametrize("entry", [
    {"path": "C:\\Windows", "argv": [PY]},                       # outside allowed_roots
    {"path": "__FILES__/nope", "argv": [PY]},                    # folder missing
    {"path": "__FILES__", "argv": []},
    {"path": "__FILES__", "argv": "claude"},
    {"path": "__FILES__", "argv": [PY, ""]},
    {"path": "__FILES__", "argv": [PY, "a\nb"]},
    {"path": "__FILES__", "argv": [PY, "a\x00b"]},
    {"path": "__FILES__", "argv": [PY, "x" * 400]},
    {"path": "__FILES__", "argv": [PY] * 20},
    {"path": "__FILES__", "argv": [PY], "shell": True},         # unknown key
    {"path": "__FILES__"},
    {"argv": [PY]},
    {"path": 5, "argv": [PY]},
    {"path": "__FILES__", "argv": ["definitely-not-a-program-xyz"]},
    "just a string",
])
def test_invalid_projects_are_dropped_with_a_problem(settings, files, entry):
    if isinstance(entry, dict) and isinstance(entry.get("path"), str):
        entry = {**entry, "path": entry["path"].replace("__FILES__", str(files))}
    settings.coding_projects = {"bad": entry}
    projects, problems = parse_projects(settings)
    assert projects == {} and len(problems) == 1


@pytest.mark.parametrize("name", ["", "../x", "a/b", "a;b", "x" * 41, "-lead", "a\nb", "añb"])
def test_bad_project_names_are_dropped(settings, files, name):
    settings.coding_projects = {name: {"path": str(files), "argv": [PY]}}
    assert parse_projects(settings)[0] == {}


def test_duplicate_names_and_wrong_types(settings, files):
    settings.coding_projects = {"Api": {"path": str(files), "argv": [PY]}, "api": {"path": str(files), "argv": [PY]}}
    projects, problems = parse_projects(settings)
    assert list(projects) == ["api"] and any("duplicate" in p for p in problems)
    settings.coding_projects = ["api"]
    assert parse_projects(settings)[0] == {}
    settings.coding_projects = None
    assert parse_projects(settings) == ({}, [])


# ----------------------------------------------------------------------- start
def test_registry_risks():
    assert REGISTRY["coding_session_start"].risk == "high"
    assert REGISTRY["coding_session_stop"].risk == "high"
    assert REGISTRY["remote_desktop_start"].risk == "high"
    assert REGISTRY["coding_session_list"].risk == "low"
    assert REGISTRY["remote_desktop_status"].risk == "low"
    assert REGISTRY["coding_session_start"].params == ("name",)      # a name, never a path/argv


def test_start_runs_exactly_the_owners_command_without_a_shell(proj, files):
    r = run(proj, "coding_session_start", name="API")
    assert r.ok, r.message
    p = FakePopen.made[0]
    assert p.cmd == [PY, "-c", "print('hi')"]
    assert p.kwargs["cwd"] == str(files)
    assert "shell" not in p.kwargs and p.kwargs["stdin"] is not None
    assert r.data["project"] == "api"


@pytest.mark.parametrize("name", ["nope", "", "../api", "api;calc", "C:\\Windows\\notepad.exe", "API ", "ap"])
def test_unknown_or_malformed_names_start_nothing(proj, name):
    r = run(proj, "coding_session_start", name=name)
    if name == "API ":
        assert r.ok            # surrounding spaces are trimmed, nothing else is
        return
    assert not r.ok and FakePopen.made == []


@pytest.mark.parametrize("extra", [{"argv": "calc"}, {"path": "C:\\"}, {"cwd": "C:\\"}, {"command": "calc"}])
def test_the_caller_cannot_add_a_program_or_path(proj, extra):
    r = run(proj, "coding_session_start", name="api", **extra)
    assert not r.ok and FakePopen.made == []


def test_start_twice_and_the_concurrency_cap(proj, settings, files):
    assert run(proj, "coding_session_start", name="api").ok
    assert not run(proj, "coding_session_start", name="api").ok
    settings.coding_projects = {f"p{i}": {"path": str(files), "argv": [PY]} for i in range(MAX_RUNNING + 1)}
    results = [run(proj, "coding_session_start", name=f"p{i}").ok for i in range(MAX_RUNNING + 1)]
    # one session ('api') is gone from config now, so count only the new ones: the cap holds
    assert sum(results) <= MAX_RUNNING


def test_not_on_windows(proj):
    proj.ctx.system = "Linux"
    assert not run(proj, "coding_session_start", name="api").ok and FakePopen.made == []


def test_emergency_stop_ends_sessions_and_blocks_new_ones(proj):
    run(proj, "coding_session_start", name="api")
    r = run(proj, "emergency_stop")
    assert r.ok and FakePopen.made[0].killed
    assert not run(proj, "coding_session_start", name="docs").ok
    assert len(FakePopen.made) == 1


def test_start_needs_the_two_step_confirmation_over_http(proj, http, auth):
    first = http.post("/actions/coding_session_start", json={"params": {"name": "api"}}, headers=auth).json()
    assert first["status"] == "confirmation_required" and FakePopen.made == []
    assert http.post("/actions/coding_session_start", json={"params": {"name": "api"}, "confirm_token": "x" * 12},
                     headers=auth).status_code == 403
    assert FakePopen.made == []
    ok = http.post("/actions/coding_session_start",
                   json={"params": {"name": "api"}, "confirm_token": first["confirm_token"]}, headers=auth)
    assert ok.json()["status"] == "ok" and len(FakePopen.made) == 1


def test_a_token_for_one_project_cannot_start_another(proj, http, auth):
    tok = http.post("/actions/coding_session_start", json={"params": {"name": "api"}}, headers=auth).json()["confirm_token"]
    r = http.post("/actions/coding_session_start", json={"params": {"name": "docs"}, "confirm_token": tok}, headers=auth)
    assert r.status_code == 403 and FakePopen.made == []


def test_unknown_project_never_even_asks_for_confirmation(proj, http, auth):
    r = http.post("/actions/coding_session_start", json={"params": {"name": "ghost"}}, headers=auth)
    assert r.status_code == 400
    assert http.get("/ai/pending", headers=auth).json() == []


def test_confirmation_card_shows_the_exact_command_and_folder(proj, http, auth, files):
    client = FakeClient([resp([tool_use("t1", "coding_session_start", name="api")], "tool_use"), resp([text("ok")])])
    Orchestrator(proj, client=client, today=lambda: "2026-10-17").run("start it", 1, "phone")
    pending = http.get("/ai/pending", headers=auth).json()
    assert pending[0]["action"] == "coding_session_start"
    assert pending[0]["command"][:3] == [PY, "-c", "print('hi')"]
    assert str(files) in pending[0]["command"]
    assert FakePopen.made == []


def test_ai_can_request_start_and_stop_but_never_run_them(proj):
    client = FakeClient([resp([tool_use("t1", "coding_session_start", name="api"),
                               tool_use("t2", "coding_session_stop", name="api"),
                               tool_use("t3", "remote_desktop_start")], "tool_use"), resp([text("waiting")])])
    r = Orchestrator(proj, client=client, today=lambda: "2026-10-17").run("go", 1, "phone")
    assert FakePopen.made == []
    assert {p["action"] for p in r.pending_confirmations} == {"coding_session_start", "coding_session_stop"} \
        or {p["action"] for p in r.pending_confirmations} >= {"coding_session_start", "coding_session_stop"}


def test_engine_refuses_these_from_the_ai_and_watcher_channels(proj):
    for action, params in (("coding_session_start", {"name": "api"}), ("coding_session_stop", {"name": "api"}),
                           ("remote_desktop_start", {})):
        assert not proj.run(action, params, "ai:x", "ai").ok
        assert not proj.run(action, params, "x", "watcher").ok
    assert FakePopen.made == []


def test_the_ai_is_not_asked_to_confirm_what_cannot_run(proj):
    client = FakeClient([resp([tool_use("t1", "coding_session_start", name="ghost")], "tool_use"), resp([text("no")])])
    r = Orchestrator(proj, client=client, today=lambda: "2026-10-17").run("go", 1, "phone")
    assert r.pending_confirmations == [] and not r.steps[0]["ok"]


def test_tools_exist_and_say_confirmation_is_needed():
    tools = {t["name"]: t for t in build_tools()}
    for name in ("coding_session_start", "coding_session_stop", "remote_desktop_start"):
        assert "Needs the owner's confirmation" in tools[name]["description"]
    assert tools["coding_session_start"]["input_schema"]["required"] == ["name"]
    assert "emergency_stop" in AI_TOOL_EXCLUDE


# ------------------------------------------------------------------------ stop
def test_stop_only_touches_sessions_this_agent_started(proj):
    r = run(proj, "coding_session_stop", name="api")           # configured but never started
    assert not r.ok and "started" in r.message
    assert FakePopen.made == []


def test_stop_ends_the_tracked_process(proj):
    run(proj, "coding_session_start", name="api")
    r = run(proj, "coding_session_stop", name="api")
    assert r.ok and FakePopen.made[0].killed


def test_stop_an_exited_session_is_refused(proj):
    run(proj, "coding_session_start", name="api")
    FakePopen.made[0].finish(0)
    assert not run(proj, "coding_session_stop", name="api").ok


@pytest.mark.parametrize("name", ["notepad", "1234", "api;calc", "../api", ""])
def test_stop_by_process_name_or_pid_is_impossible(proj, name):
    run(proj, "coding_session_start", name="api")
    assert not run(proj, "coding_session_stop", name=name).ok
    assert not FakePopen.made[0].killed


def test_stop_needs_confirmation_over_http(proj, http, auth):
    run(proj, "coding_session_start", name="api")
    first = http.post("/actions/coding_session_stop", json={"params": {"name": "api"}}, headers=auth).json()
    assert first["status"] == "confirmation_required" and not FakePopen.made[0].killed
    http.post("/actions/coding_session_stop", json={"params": {"name": "api"}, "confirm_token": first["confirm_token"]},
              headers=auth)
    assert FakePopen.made[0].killed


# ------------------------------------------------------------------------ list
def test_list_shows_states_without_commands_or_paths(proj, files):
    r = run(proj, "coding_session_list")
    assert [p["state"] for p in r.data["projects"]] == ["not started", "not started"]
    run(proj, "coding_session_start", name="api")
    r = run(proj, "coding_session_list")
    states = {p["project"]: p["state"] for p in r.data["projects"]}
    assert states == {"api": "running", "docs": "not started"}
    FakePopen.made[0].finish(3)
    r = run(proj, "coding_session_list")
    row = [p for p in r.data["projects"] if p["project"] == "api"][0]
    assert row["state"] == "exited" and row["exit_code"] == 3
    dump = str(r.data) + r.message
    assert PY not in dump and str(files) not in dump and "print" not in dump


def test_list_includes_the_watch_rules_states(proj, settings):
    settings.watched_programs = ["claude"]
    settings.watch_rules = [{"name": "coder-done", "kind": "process_exit", "target": "claude", "minutes": 0}]
    r = run(proj, "coding_session_list")
    assert r.data["watch"] == [{"rule": "coder-done", "state": "waiting"}]


def test_list_result_is_fenced_for_the_ai(proj):
    client = FakeClient([resp([tool_use("t1", "coding_session_list")], "tool_use"), resp([text("ok")])])
    Orchestrator(proj, client=client, today=lambda: "2026-10-17").run("status?", 1, "phone")
    result = client.calls[1]["messages"][-1]["content"][0]["content"]
    assert result.startswith('<tool_output untrusted="true">')


def test_exit_makes_an_alert_with_a_fixed_sentence(proj):
    sent = []

    class N:
        def notify(self, event, pct, when):
            sent.append(event)

    proj.notifier = N()
    run(proj, "coding_session_start", name="api")
    FakePopen.made[0].finish(7)
    assert wait_for(lambda: proj.alerts.recent(5, scope="watch"))
    assert wait_for(lambda: sent and any(a["action"] == "coding_session_exit" for a in proj.audit.recent(10)))
    alert = proj.alerts.recent(5, scope="watch")[0]
    assert alert["kind"] == "watch_session_exit" and "exit code 7" in alert["message"]
    assert sent == ["Coding session 'api' ended (exit code 7)"]
    assert any(a["action"] == "coding_session_exit" for a in proj.audit.recent(10))


def test_a_failing_exit_hook_does_not_break_anything(proj):
    class Bad:
        def notify(self, *a):
            raise RuntimeError("boom")

    proj.notifier = Bad()
    run(proj, "coding_session_start", name="api")
    FakePopen.made[0].finish(0)
    assert wait_for(lambda: proj.alerts.recent(5, scope="watch"))
    assert run(proj, "coding_session_list").ok


def test_project_names_only_in_capabilities(proj, http, auth, files):
    body = http.get("/capabilities", headers=auth).json()
    assert body["coding_projects"] == ["api", "docs"]
    dump = str(body)
    # the interpreter/argv must never appear anywhere in /capabilities
    assert PY not in dump
    # project folders must not be exposed through the project list itself.
    # (The same folder may legitimately appear as an *allowed root*, which is
    # listed by design; on Linux the test fixture uses one folder for both.)
    assert str(files) not in str(body["coding_projects"])
    assert "argv" not in dump


def test_precheck_helper():
    class S:
        approved_scripts = {"backup": ["x"]}
        coding_projects = {}
        allowed_apps = {"notepad": ["notepad.exe"]}
        remote_desktop_app = "rustdesk"
        allowed_roots = []

    assert precheck_high(S, "run_script", {"name": "backup"}) is None
    assert precheck_high(S, "run_script", {"name": "evil"})
    assert precheck_high(S, "coding_session_start", {"name": "x"})
    assert precheck_high(S, "remote_desktop_start", {})
    assert precheck_high(S, "shutdown", {}) is None


# --------------------------------------------------------------- remote desktop
def test_status_reports_running_and_not_running(engine, settings):
    engine.ctx.process_names = lambda: ["System", "RustDesk.exe", "node.exe"]
    r = run(engine, "remote_desktop_status")
    assert r.ok and r.data["running"] is True and "running" in r.message
    engine.ctx.process_names = lambda: ["System", "node.exe"]
    r = run(engine, "remote_desktop_status")
    assert r.data["running"] is False


def test_status_needs_a_plain_process_name(engine, settings):
    engine.ctx.process_names = lambda: []
    for bad in ("", "C:\\Program Files\\RustDesk\\rustdesk.exe", "a b", "../x", "x" * 50):
        settings.remote_desktop_process = bad
        assert not run(engine, "remote_desktop_status").ok


def test_status_does_not_touch_the_runner_or_any_file(engine, runner, settings):
    engine.ctx.process_names = lambda: ["rustdesk"]
    run(engine, "remote_desktop_status")
    assert runner.calls == []


def test_start_uses_the_allowlisted_app_only(engine, settings, launched):
    r = run(engine, "remote_desktop_start")
    assert not r.ok and launched == []                 # not in allowed_apps
    settings.allowed_apps["rustdesk"] = ["C:\\Program Files\\RustDesk\\rustdesk.exe"]
    r = run(engine, "remote_desktop_start")
    assert r.ok and launched == [["C:\\Program Files\\RustDesk\\rustdesk.exe"]]


def test_start_needs_confirmation_over_http(engine, settings, http, auth, launched):
    settings.allowed_apps["rustdesk"] = ["rustdesk.exe"]
    first = http.post("/actions/remote_desktop_start", json={}, headers=auth).json()
    assert first["status"] == "confirmation_required" and launched == []
    http.post("/actions/remote_desktop_start", json={"confirm_token": first["confirm_token"]}, headers=auth)
    assert launched == [["rustdesk.exe"]]


def test_start_without_the_app_never_asks_for_confirmation(engine, http, auth):
    assert http.post("/actions/remote_desktop_start", json={}, headers=auth).status_code == 400


def test_the_caller_cannot_pick_the_program_to_start(engine, settings, launched):
    settings.allowed_apps["rustdesk"] = ["rustdesk.exe"]
    settings.allowed_apps["notepad"] = ["notepad.exe"]
    r = run(engine, "remote_desktop_start", name="notepad")
    assert not r.ok and launched == []


def test_ai_can_request_remote_desktop_start_only(engine, settings, launched):
    settings.allowed_apps["rustdesk"] = ["rustdesk.exe"]
    client = FakeClient([resp([tool_use("t1", "remote_desktop_start")], "tool_use"), resp([text("waiting")])])
    r = Orchestrator(engine, client=client, today=lambda: "2026-10-17").run("remote", 1, "phone")
    assert launched == [] and [p["action"] for p in r.pending_confirmations] == ["remote_desktop_start"]


# ----------------------------------------------------------------------- doctor
def test_doctor_reports_project_problems(proj, settings):
    settings.coding_projects["bad"] = {"path": "C:\\Windows", "argv": [PY]}
    checks = run_checks(settings, env={}, startup_probe=lambda: None)
    text_ = "\n".join(c.line() for c in checks)
    assert "coding_projects problem" in text_ and "2 coding project(s) valid" in text_
    assert "RustDesk) is not in allowed_apps" in text_
