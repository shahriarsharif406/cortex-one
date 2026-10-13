import pytest

from agent.sms import SmsHandler, normalize_number, parse_sms

PHONE = "01711111111"


@pytest.mark.parametrize("raw,expected", [
    ("01711111111", "+8801711111111"),
    ("+880 1711-111111", "+8801711111111"),
    ("8801711111111", "+8801711111111"),
    ("008801711111111", "+8801711111111"),
    ("", ""),
])
def test_normalize_number(raw, expected):
    assert normalize_number(raw) == expected


@pytest.mark.parametrize("text,expected", [
    ("SHUTDOWN 4821", ("SHUTDOWN", "4821")),
    ("  shutdown   4821 ", ("SHUTDOWN", "4821")),
    ("lock ৪৮২১", ("LOCK", "4821")),          # Bangla digits
    ("SHUTDOWN", None),
    ("SHUTDOWN 12", None),                    # PIN too short
    ("FORMAT 4821", None),                    # not a command
    ("SHUTDOWN 4821 now", None),
    ("SHUTDOWN abcd", None),
    ("", None),
])
def test_parse_sms(text, expected):
    assert parse_sms(text) == expected


def test_valid_shutdown_runs(engine, runner):
    reply = SmsHandler(engine).handle(PHONE, "SHUTDOWN 4821")
    assert runner.calls == [["shutdown", "/s", "/t", "30"]]
    assert "Shutting down" in reply


def test_cancel_and_stop(engine, runner):
    h = SmsHandler(engine)
    h.handle(PHONE, "SHUTDOWN 4821")
    h.handle(PHONE, "CANCEL 4821")
    assert runner.calls[-1] == ["shutdown", "/a"]
    assert "Stopped" in h.handle(PHONE, "STOP 4821")


def test_status_reply_is_short(engine):
    reply = SmsHandler(engine).handle(PHONE, "STATUS 4821")
    assert reply and len(reply) <= 160


def test_unknown_sender_is_silent_and_logged(engine, runner):
    assert SmsHandler(engine).handle("01999999999", "SHUTDOWN 4821") is None
    assert runner.calls == []
    assert engine.audit.recent(1)[0]["status"] == "rejected"


def test_sender_number_masked_in_audit(engine):
    SmsHandler(engine).handle(PHONE, "STATUS 4821")
    actors = {r["actor"] for r in engine.audit.recent(10)}
    assert "sms:***1111" in actors
    assert not any("8801711111111" in a for a in actors)


def test_wrong_pin_locks_sender_out(engine, runner):
    h = SmsHandler(engine)
    for _ in range(engine.settings.sms_max_failures):
        assert h.handle(PHONE, "SHUTDOWN 0000") == "Wrong PIN."
    # now even the right PIN is ignored (silent) while locked
    assert h.handle(PHONE, "SHUTDOWN 4821") is None
    assert runner.calls == []


def test_sms_disabled_without_pin(engine, runner):
    engine.settings.sms_pin_hash = ""
    assert SmsHandler(engine).handle(PHONE, "SHUTDOWN 4821") is None
    assert runner.calls == []


def test_bad_format_gets_help_not_action(engine, runner):
    reply = SmsHandler(engine).handle(PHONE, "please shut down")
    assert "Format" in reply and runner.calls == []


def test_only_small_command_set_exposed(engine, runner):
    h = SmsHandler(engine)
    for cmd in ("RUN_SCRIPT", "COPY", "OPEN", "DELETE"):
        assert "Format" in h.handle(PHONE, f"{cmd} 4821")
    assert runner.calls == []
