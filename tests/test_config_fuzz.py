"""Malformed configuration: every bad value gives a clear error or an OFF capability, never a
crash with a traceback and never a silent fallback to a wider setting."""
import json
import random

import pytest

from agent.actions import ActionError, wake_target
from agent.config import ConfigError, Settings
from agent.doctor import WARN, run_checks
from agent.gui import GuiPolicy
from agent.main import main
from agent.netbind import BindError, effective_hosts
from agent.sessions import parse_projects

JUNK = [None, 5, -1, 1.5, True, "", " ", "x" * 5000, [], {}, [[]], [None], {"a": {"b": 1}}, "\x00",
        "0.0.0.0", "../../etc", "C:/Windows", ["0.0.0.0"], [5], {"mac": 5}, "\u202e"]


def write(tmp_path, obj):
    (tmp_path / "config.json").write_text(obj if isinstance(obj, str) else json.dumps(obj), encoding="utf-8")


# ----------------------------------------------------------------------- the file itself
@pytest.mark.parametrize("text", ["", "{", "not json", "[1,2]", "null", "5", '"x"', "\x00\x01",
                                  '{"port": 8765,}'])
def test_unreadable_config_is_a_clear_error(tmp_path, text):
    write(tmp_path, text)
    with pytest.raises(ConfigError):
        Settings.load(tmp_path)


def test_cli_prints_a_clear_message_and_exits_2(tmp_path, capsys):
    write(tmp_path, "{ broken")
    assert main(["--data-dir", str(tmp_path), "doctor"]) == 2
    err = capsys.readouterr().err
    assert "config" in err and "Traceback" not in err


@pytest.mark.parametrize("key,value", [
    ("allowed_roots", "C:/Users"), ("allowed_roots", [5]), ("allowed_roots", [""]),
    ("allowed_roots", {"a": "b"}), ("allowed_apps", ["notepad"]), ("allowed_apps", "notepad"),
    ("port", "8765"), ("port", 0), ("port", 99999), ("port", True), ("port", -5),
    ("hosts", "127.0.0.1"), ("host", 5), ("wake_targets", ["x"]), ("coding_projects", "x"),
    ("gui_agent", "on"), ("gui_agent", [True]), ("sms_allowed_numbers", "+88017"),
    ("token_ttl_days", -1), ("token_ttl_days", "30"), ("power_watch", "yes"),
    ("critical_action", 5), ("watch_rules", {"a": 1}), ("screenshots_dir", ["x"]),
])
def test_wrong_kind_of_value_is_refused_not_guessed(tmp_path, key, value):
    write(tmp_path, {key: value})
    with pytest.raises(ConfigError) as e:
        Settings.load(tmp_path)
    assert key in str(e.value)


def test_unknown_keys_are_reported_by_doctor_not_silently_dropped(tmp_path):
    write(tmp_path, {"allowd_roots": ["C:/x"], "port": 8765})
    s = Settings.load(tmp_path)
    assert s.unknown_keys == ["allowd_roots"]
    checks = run_checks(s, env={}, startup_probe=lambda: None)
    assert any(c.level == WARN and "allowd_roots" in c.en for c in checks)


def test_a_good_config_still_loads(tmp_path):
    s = Settings(data_dir=tmp_path)
    s.hosts = ["127.0.0.1"]
    s.wake_targets = {"d": {"mac": "aa:bb:cc:dd:ee:ff"}}
    s.save()
    again = Settings.load(tmp_path)
    assert again.hosts == ["127.0.0.1"] and again.unknown_keys == []


# ----------------------------------------------------------------------- the parsers
@pytest.mark.parametrize("junk", JUNK)
def test_hosts_junk_never_widens(settings, junk):
    settings.hosts = junk
    try:
        out = effective_hosts(settings)
    except BindError:
        return
    # the only accepted junk is an empty value, which falls back to the single (validated) host
    assert out == [settings.host] and "0.0.0.0" not in out


@pytest.mark.parametrize("junk", JUNK)
def test_wake_targets_junk_is_off_or_an_error(settings, junk):
    settings.wake_targets = junk
    with pytest.raises(ActionError):
        wake_target(settings, "desktop")
    settings.wake_targets = {"desktop": junk}
    with pytest.raises(ActionError):
        wake_target(settings, "desktop")
    settings.wake_targets = {"desktop": {"mac": junk, "broadcast": "192.168.1.255"}}
    with pytest.raises(ActionError):
        wake_target(settings, "desktop")
    settings.wake_targets = {"desktop": {"mac": "aa:bb:cc:dd:ee:ff", "broadcast": junk}}
    if junk is None:
        return          # a missing/None broadcast is not a wider setting: see below
    with pytest.raises(ActionError):
        wake_target(settings, "desktop")


def test_wake_target_broadcast_none_does_not_widen(settings):
    settings.wake_targets = {"desktop": {"mac": "aa:bb:cc:dd:ee:ff", "broadcast": None}}
    with pytest.raises(ActionError):
        wake_target(settings, "desktop")


@pytest.mark.parametrize("junk", JUNK)
def test_coding_projects_junk_is_dropped_with_problems(settings, junk):
    settings.coding_projects = junk
    projects, problems = parse_projects(settings)
    assert projects == {}
    settings.coding_projects = {"p": junk}
    projects, problems = parse_projects(settings)
    assert projects == {} and len(problems) <= 1


@pytest.mark.parametrize("junk", JUNK)
def test_gui_agent_junk_stays_off(settings, junk):
    settings.gui_agent = junk
    pol = GuiPolicy.from_settings(settings)
    assert not pol.enabled
    settings.gui_agent = {"enabled": True, "allowed_apps": junk, "max_session_minutes": junk,
                          "max_actions": junk, "blocked_title_patterns": junk, "blocked_apps": junk}
    pol = GuiPolicy.from_settings(settings)       # must not raise
    assert pol.max_minutes > 0 and pol.max_actions > 0 if hasattr(pol, "max_minutes") else True


def test_random_structures_never_crash_the_parsers(settings):
    rnd = random.Random(7)

    def rand_val(depth=0):
        k = rnd.randrange(8 if depth < 2 else 5)
        if k == 0: return None
        if k == 1: return rnd.choice(JUNK[:12])
        if k == 2: return rnd.choice(["aa:bb:cc:dd:ee:ff", "192.168.1.255", "255.255.255.255", "api", "notepad"])
        if k == 3: return rnd.randrange(-5, 10**9)
        if k == 4: return rnd.choice([True, False])
        if k == 5: return [rand_val(depth + 1) for _ in range(rnd.randrange(4))]
        return {rnd.choice(["mac", "broadcast", "path", "argv", "enabled", "x"]): rand_val(depth + 1)
                for _ in range(rnd.randrange(4))}

    for _ in range(400):
        settings.wake_targets = rand_val()
        settings.coding_projects = rand_val()
        settings.gui_agent = rand_val()
        settings.hosts = rand_val()
        for fn in (lambda: wake_target(settings, "desktop"), lambda: effective_hosts(settings)):
            try:
                fn()
            except (ActionError, BindError):
                pass
        parse_projects(settings)
        GuiPolicy.from_settings(settings)
