import time

import pytest

from agent.schedule import Scheduler, allowed_action, parse_schedules


def sched(settings, *items):
    settings.schedules = list(items)
    return parse_schedules(settings)


OK = {"name": "usage", "action": "disk_usage_report", "every_minutes": 60}


def test_valid_rules(settings, files):
    rules, problems = sched(settings, {**OK, "params": {"root": str(files)}},
                            {"name": "info", "action": "system_info", "daily_at": "08:30"})
    assert not problems and [r.name for r in rules] == ["usage", "info"]


@pytest.mark.parametrize("bad", [
    {"name": "x", "action": "shutdown", "every_minutes": 60},                    # high risk
    {"name": "x", "action": "archive_file", "params": {"src": "a"}, "every_minutes": 60},
    {"name": "x", "action": "emergency_stop", "every_minutes": 60},
    {"name": "x", "action": "nope", "every_minutes": 60},
    {"name": "x", "action": "system_info"},                                      # no time
    {"name": "x", "action": "system_info", "every_minutes": 60, "daily_at": "08:30"},
    {"name": "x", "action": "system_info", "every_minutes": 1},                  # too often
    {"name": "x", "action": "system_info", "every_minutes": True},
    {"name": "x", "action": "system_info", "daily_at": "25:00"},
    {"name": "../x", "action": "system_info", "every_minutes": 60},
    {"name": "x", "action": "disk_usage_report", "every_minutes": 60},           # missing param
    {"name": "x", "action": "system_info", "params": {"evil": "1"}, "every_minutes": 60},
    {"name": "x", "action": "disk_usage_report", "params": {"root": 5}, "every_minutes": 60},
    "text", 5])
def test_bad_rules_are_rejected(settings, bad):
    rules, problems = sched(settings, bad)
    assert rules == [] and problems


def test_duplicates_and_limits(settings):
    rules, problems = sched(settings, {**OK, "action": "system_info", "name": "a"},
                            {"name": "A", "action": "system_info", "every_minutes": 60})
    assert len(rules) == 1 and problems
    many = [{"name": f"s{i}", "action": "system_info", "every_minutes": 60} for i in range(25)]
    assert len(sched(settings, *many)[0]) == 20


def test_not_a_list(settings):
    settings.schedules = {"a": 1}
    assert parse_schedules(settings)[0] == []


def test_high_and_excluded_never_schedulable():
    assert not allowed_action("shutdown") and not allowed_action("emergency_stop")
    assert not allowed_action("archive_file") and allowed_action("system_info")


def test_interval_runs_once_then_waits(engine, settings):
    sched(settings, {"name": "i", "action": "system_info", "every_minutes": 10})
    t = [1_000_000.0]
    sc = Scheduler(engine, clock=lambda: t[0])
    assert sc.run_due() == ["i"]
    assert sc.run_due() == []
    t[0] += 599
    assert sc.run_due() == []
    t[0] += 2
    assert sc.run_due() == ["i"]
    rows = engine.audit.recent(10)
    assert rows[0]["via"] == "schedule" and rows[0]["action"] == "system_info"
    kinds = [a["kind"] for a in engine.alerts.recent(10)]
    assert "watch_schedule" in kinds


def test_restart_does_not_repeat_and_state_survives(engine, settings):
    sched(settings, {"name": "i", "action": "system_info", "every_minutes": 10})
    now = [2_000_000.0]
    assert Scheduler(engine, clock=lambda: now[0]).run_due() == ["i"]
    assert Scheduler(engine, clock=lambda: now[0] + 5).run_due() == []   # "restarted" agent


def test_daily_runs_once_per_day(engine, settings):
    lt = time.localtime()
    sched(settings, {"name": "d", "action": "system_info", "daily_at": "08:30"})
    slot = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 8, 30, 0, 0, 0, -1))
    sc = Scheduler(engine, clock=lambda: slot - 3600)
    engine.db.kv_set("schedule_last:d", str(slot - 86400 + 60))   # ran yesterday after its slot
    assert sc.run_due() == []                                    # today's slot not reached
    sc.clock = lambda: slot + 120
    assert sc.run_due() == ["d"] and sc.run_due() == []
    sc.clock = lambda: slot + 86400 + 120
    assert sc.run_due() == ["d"]


def test_failed_run_is_reported_without_output(engine, settings):
    sched(settings, {"name": "bad", "action": "disk_usage_report",
                     "params": {"root": "Z:\\nowhere-secret-path"}, "every_minutes": 10})
    Scheduler(engine, clock=lambda: 3_000_000.0).run_due()
    msgs = " ".join(a["message"] for a in engine.alerts.recent(10))
    assert "failed" in msgs and "nowhere-secret-path" not in msgs


def test_channel_is_reserved_and_rechecked(engine):
    assert not engine.run("system_info", {}, actor="x", via="schedule").ok
    assert not engine.run_scheduled("x", "shutdown", {}).ok
    assert not engine.run_scheduled("x", "emergency_stop", {}).ok
    assert not engine.run_scheduled("x", "archive_file", {"src": "a"}).ok


def test_start_without_rules_starts_no_thread(engine, settings):
    settings.schedules = []
    sc = Scheduler(engine)
    sc.start()
    assert sc._thread is None


def test_schedules_roundtrip_in_config(tmp_path):
    from agent.config import Settings
    s = Settings(data_dir=tmp_path / "d")
    s.schedules = [{"name": "a", "action": "system_info", "every_minutes": 60}]
    s.archive_dir = tmp_path / "arc"
    s.save()
    t = Settings.load(tmp_path / "d")
    assert t.schedules == s.schedules and t.archive_dir == tmp_path / "arc"
