import base64
import sys

import pytest

from agent import main as cli
from agent import totp
from agent.sms import SmsHandler
from agent.totp import ReplayGuard

PHONE = "01711111111"
SECRET = base64.b32encode(b"12345678901234567890").decode()      # RFC 6238 test key
T0 = 1_700_000_010.0                                              # step = T0 // 30


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def totp_engine(engine, settings):
    settings.sms_mode = "totp"
    settings.sms_pin_hash = ""
    totp.save_secret(settings.data_dir, SECRET)
    return engine


def handler(engine, clock):
    return SmsHandler(engine, now=clock)


# ------------------------------------------------------------- the algorithm
@pytest.mark.parametrize("t,expected", [      # RFC 6238 appendix B (SHA1), last 6 digits
    (59, "287082"), (1111111109, "081804"), (1111111111, "050471"),
    (1234567890, "005924"), (2000000000, "279037"), (20000000000, "353130")])
def test_rfc6238_vectors(t, expected):
    assert totp.totp(SECRET, t) == expected


def test_new_secret_is_random_base32():
    a, b = totp.new_secret(), totp.new_secret()
    assert a != b and len(a) == 32 and base64.b32decode(a)


def test_window_is_plus_minus_one_step():
    step = totp.current_step(T0)
    for delta, ok in ((-2, False), (-1, True), (0, True), (1, True), (2, False)):
        code = totp.hotp(SECRET, step + delta)
        assert (totp.match_step(SECRET, code, T0) is not None) is ok


@pytest.mark.parametrize("bad", ["", "12345", "1234567", "abcdef", "12 456", "١٢٣٤٥٦", None, 123456])
def test_malformed_codes_never_match(bad):
    assert totp.match_step(SECRET, bad, T0) is None


# ------------------------------------------------------------- sms handler
def test_valid_code_runs_command(totp_engine, runner):
    clock = Clock()
    code = totp.totp(SECRET, clock.t)
    reply = handler(totp_engine, clock).handle(PHONE, f"SHUTDOWN {code}")
    assert runner.calls == [["shutdown", "/s", "/t", "30"]]
    assert "Shutting down" in reply


def test_replay_of_same_code_is_rejected(totp_engine, runner):
    clock = Clock()
    h = handler(totp_engine, clock)
    code = totp.totp(SECRET, clock.t)
    h.handle(PHONE, f"LOCK {code}")
    assert len(runner.calls) == 1
    assert h.handle(PHONE, f"SHUTDOWN {code}") == "Wrong code."      # captured SMS replayed
    assert len(runner.calls) == 1


def test_replay_survives_agent_restart(totp_engine, runner):
    clock = Clock()
    code = totp.totp(SECRET, clock.t)
    handler(totp_engine, clock).handle(PHONE, f"LOCK {code}")
    fresh = handler(totp_engine, clock)                  # new handler, same database
    assert fresh.handle(PHONE, f"SHUTDOWN {code}") == "Wrong code."
    assert len(runner.calls) == 1


def test_older_step_is_rejected_after_a_newer_one(totp_engine, runner):
    clock = Clock()
    step = totp.current_step(clock.t)
    h = handler(totp_engine, clock)
    h.handle(PHONE, f"LOCK {totp.hotp(SECRET, step + 1)}")           # uses the future step
    assert h.handle(PHONE, f"LOCK {totp.hotp(SECRET, step)}") == "Wrong code."
    assert len(runner.calls) == 1


def test_expired_code_is_rejected(totp_engine, runner):
    clock = Clock()
    code = totp.totp(SECRET, clock.t)
    clock.t += 3 * 30                                    # three steps later
    assert handler(totp_engine, clock).handle(PHONE, f"SHUTDOWN {code}") == "Wrong code."
    assert runner.calls == []


def test_one_step_either_side_is_accepted(totp_engine, runner):
    clock = Clock()
    step = totp.current_step(clock.t)
    h = handler(totp_engine, clock)
    assert "Locked" in h.handle(PHONE, f"LOCK {totp.hotp(SECRET, step - 1)}")
    clock.t += 30                                         # next code, again valid
    assert "Locked" in h.handle(PHONE, f"LOCK {totp.hotp(SECRET, step + 2)}")


def test_wrong_code_locks_the_sender_out(totp_engine, runner):
    clock = Clock()
    h = handler(totp_engine, clock)
    good = totp.totp(SECRET, clock.t)
    wrong = "000000" if good != "000000" else "111111"
    for _ in range(3):
        assert h.handle(PHONE, f"SHUTDOWN {wrong}") == "Wrong code."
    assert h.handle(PHONE, f"SHUTDOWN {good}") is None    # locked: silent
    assert runner.calls == []


def test_replay_attempts_also_count_toward_lockout(totp_engine, runner):
    clock = Clock()
    h = handler(totp_engine, clock)
    code = totp.totp(SECRET, clock.t)
    h.handle(PHONE, f"LOCK {code}")
    for _ in range(3):
        h.handle(PHONE, f"LOCK {code}")
    assert h.handle(PHONE, f"LOCK {totp.hotp(SECRET, totp.current_step(clock.t) + 1)}") is None


def test_static_pin_does_not_work_in_totp_mode(totp_engine, runner):
    assert handler(totp_engine, Clock()).handle(PHONE, "SHUTDOWN 4821") == "Wrong code."
    assert runner.calls == []


def test_unknown_sender_still_silent_in_totp_mode(totp_engine, runner):
    clock = Clock()
    code = totp.totp(SECRET, clock.t)
    assert handler(totp_engine, clock).handle("01999999999", f"SHUTDOWN {code}") is None
    assert runner.calls == []


def test_totp_mode_without_a_secret_is_disabled(engine, settings, runner):
    settings.sms_mode = "totp"
    assert SmsHandler(engine).handle(PHONE, "SHUTDOWN 123456") is None
    assert runner.calls == []


def test_secret_and_codes_never_reach_audit(totp_engine):
    clock = Clock()
    h = handler(totp_engine, clock)
    code = totp.totp(SECRET, clock.t)
    h.handle(PHONE, f"LOCK {code}")
    h.handle(PHONE, f"LOCK {code}")
    h.handle(PHONE, "LOCK 999999")
    dump = repr(totp_engine.audit.recent(50))
    assert SECRET not in dump and code not in dump and "999999" not in dump


# ------------------------------------------------------------- replay guard (unit)
def test_replay_guard_claims_each_step_once(engine):
    g = ReplayGuard(engine.db)
    assert g.claim(100) is True
    assert g.claim(100) is False
    assert g.claim(99) is False
    assert g.claim(101) is True


# ------------------------------------------------------------- storage
@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI is Windows only")
def test_dpapi_roundtrip_and_file_is_not_plaintext(tmp_path):
    how = totp.save_secret(tmp_path, SECRET)
    assert how == "dpapi"
    raw = totp.secret_path(tmp_path).read_bytes()
    assert SECRET.encode() not in raw and raw.startswith(b"DPAPI1:")
    assert totp.load_secret(tmp_path) == SECRET


def test_plain_fallback_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setattr(totp, "_on_windows", lambda: False)
    assert totp.save_secret(tmp_path, SECRET) == "plain-600"
    assert totp.load_secret(tmp_path) == SECRET


def test_load_secret_handles_missing_and_garbage(tmp_path):
    assert totp.load_secret(tmp_path) is None
    totp.secret_path(tmp_path).write_bytes(b"garbage")
    assert totp.load_secret(tmp_path) is None


# ------------------------------------------------------------- CLI
def test_sms_setup_totp_prints_secret_once_and_keeps_it_out_of_files(tmp_path, capsys):
    rc = cli.main(["--data-dir", str(tmp_path), "sms-setup", "--totp", PHONE])
    assert rc == 0
    out = capsys.readouterr()
    secret = totp.load_secret(tmp_path)
    assert secret and secret in out.out
    assert secret not in (tmp_path / "config.json").read_text(encoding="utf-8")
    assert "sms_mode\": \"totp\"" in (tmp_path / "config.json").read_text(encoding="utf-8")
    assert '"sms_pin_hash": ""' in (tmp_path / "config.json").read_text(encoding="utf-8")
    for p in tmp_path.rglob("*"):
        if p.is_file() and p.name != totp.SECRET_FILE and p.suffix != ".db":
            assert secret.encode() not in p.read_bytes()


def test_sms_setup_pin_mode_warns_about_replay(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr("getpass.getpass", lambda prompt="": "4821")
    assert cli.main(["--data-dir", str(tmp_path), "sms-setup", PHONE]) == 0
    assert "no replay protection" in capsys.readouterr().out
