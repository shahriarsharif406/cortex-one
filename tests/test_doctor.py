import json
import logging
import socket

from agent.config import Settings
from agent.doctor import FAIL, OK, WARN, format_report, run_checks
from agent.logging_setup import scrub, setup_logging
from agent.main import main


def levels(checks, needle):
    return [c.level for c in checks if needle in c.en or needle in c.bn]


def test_doctor_healthy_setup(settings, files):
    settings.port = 0  # bind probe on port 0 always succeeds
    checks = run_checks(settings, env={"ANTHROPIC_API_KEY": "sk-ant-SECRETVALUE"})
    assert levels(checks, "ANTHROPIC_API_KEY") == [OK]
    assert levels(checks, "allowed root exists") == [OK]
    text = format_report(checks)
    assert "SECRETVALUE" not in text and "sk-ant" not in text  # key never printed


def test_doctor_reports_missing_key_as_warning(settings):
    checks = run_checks(settings, env={})
    assert levels(checks, "ANTHROPIC_API_KEY") == [WARN]


def test_doctor_fails_on_wildcard_host(settings):
    settings.host = "0.0.0.0"
    assert FAIL in levels(run_checks(settings, env={}), "0.0.0.0")


def test_doctor_detects_busy_port(settings):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        settings.host, settings.port = "127.0.0.1", s.getsockname()[1]
        assert WARN in levels(run_checks(settings, env={}), "is in use")


def test_doctor_old_python_fails(settings):
    assert FAIL in levels(run_checks(settings, env={}, version=(3, 8)), "too old")


def test_doctor_missing_root_and_app_and_bad_config(settings, tmp_path):
    settings.allowed_roots = [tmp_path / "nope"]
    settings.allowed_apps = {"ghost": [str(tmp_path / "ghost.exe")]}
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    settings.config_path.write_text("{not json", encoding="utf-8")
    checks = run_checks(settings, env={})
    assert WARN in levels(checks, "allowed root missing")
    assert WARN in levels(checks, "app not found")
    assert FAIL in levels(checks, "unreadable")


def test_doctor_sms_state(settings):
    # a static PIN works but is flagged: it has no replay protection
    assert levels(run_checks(settings, env={}), "SMS is set up") == [WARN]
    assert WARN in levels(run_checks(settings, env={}), "no replay protection")
    settings.sms_pin_hash = ""
    assert WARN in levels(run_checks(settings, env={}), "SMS not set up")


def test_doctor_screenshots_outside_roots_warns(settings, tmp_path):
    settings.screenshots_dir = tmp_path / "elsewhere"
    assert WARN in levels(run_checks(settings, env={}), "outside allowed_roots")


def test_doctor_command_exit_code(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    rc = main(["--data-dir", str(tmp_path / "d"), "doctor"])
    out = capsys.readouterr().out
    assert rc == 0 and "Python" in out and "সারাংশ" in out


def test_init_config_writes_defaults_only_once(tmp_path, capsys):
    d = tmp_path / "d"
    assert main(["--data-dir", str(d), "init-config"]) == 0
    cfg = d / "config.json"
    raw = json.loads(cfg.read_text(encoding="utf-8"))
    assert raw["host"] == "127.0.0.1" and raw["approved_scripts"] == {}
    assert set(raw["allowed_apps"]) == {"notepad", "calculator", "explorer"}
    assert [p.split("\\")[-1].split("/")[-1] for p in raw["allowed_roots"]] == [
        "Downloads", "Documents"]
    cfg.write_text(json.dumps({"port": 9999}), encoding="utf-8")
    assert main(["--data-dir", str(d), "init-config"]) == 0
    assert json.loads(cfg.read_text(encoding="utf-8")) == {"port": 9999}  # untouched
    assert Settings.load(d).port == 9999


def test_settings_roundtrip_with_new_fields(tmp_path):
    s = Settings(data_dir=tmp_path)
    s.allowed_domains = ["example.com"]
    s.allowed_logs = {"agent": "C:\\x\\a.log"}
    s.save()
    again = Settings.load(tmp_path)
    assert again.allowed_domains == ["example.com"]
    assert again.allowed_logs == {"agent": "C:\\x\\a.log"}
    assert again.screenshots_dir == s.screenshots_dir


def test_scrub_removes_secrets():
    text = ('Authorization: Bearer abc123.DEF  key sk-ant-api03-XYZ_1  '
            'X-Gateway-Secret: hunter2 {"token": "t0k", "pin": "4821"}')
    cleaned = scrub(text)
    for secret in ("abc123", "sk-ant-api03", "hunter2", "t0k", "4821"):
        assert secret not in cleaned


def test_file_logging_rotates_and_redacts(settings):
    settings.log_max_bytes, settings.log_backups = 2000, 2
    handler = setup_logging(settings)
    try:
        log = logging.getLogger("cortex")
        log.info("call with Bearer SUPERSECRETTOKEN")
        for i in range(200):
            log.info("line %d padding padding padding padding", i)
        handler.flush()
    finally:
        logging.getLogger().removeHandler(handler)
        handler.close()
    files_ = sorted(p.name for p in settings.logs_dir.iterdir())
    everything = "".join((settings.logs_dir / n).read_text(encoding="utf-8") for n in files_)
    assert everything.count("line 199 ") <= 1   # never duplicated across handlers
    assert "agent.log" in files_ and "agent.log.1" in files_
    assert all("SUPERSECRETTOKEN" not in (settings.logs_dir / n).read_text(encoding="utf-8")
               for n in files_)


# ----------------------------------------------------------- new checks (Phase 5)
def probe_checks(settings, **kw):
    kw.setdefault("startup_probe", lambda: "ready")
    kw.setdefault("battery_probe", lambda: object())
    return run_checks(settings, env=kw.pop("env", {}), **kw)


def test_doctor_startup_task_states(settings):
    assert OK in levels(probe_checks(settings, startup_probe=lambda: "ready"), "startup task is installed")
    assert WARN in levels(probe_checks(settings, startup_probe=lambda: "missing"), "startup task not installed")
    assert WARN in levels(probe_checks(settings, startup_probe=lambda: "disabled"), "startup task is disabled")
    assert WARN in levels(probe_checks(settings, startup_probe=lambda: None), "could not be checked")


def test_doctor_battery_detected_or_not(settings):
    assert OK in levels(probe_checks(settings), "battery detected")
    assert WARN in levels(probe_checks(settings, battery_probe=lambda: None), "no battery detected")


def test_doctor_tailscale_host(settings):
    settings.host = "100.101.102.103"
    assert OK in levels(probe_checks(settings), "Tailscale IP")
    settings.host = "127.0.0.1"
    assert WARN in levels(probe_checks(settings), "loopback")
    settings.host = "192.168.0.5"
    assert WARN in levels(probe_checks(settings), "only a LAN IP")


def test_doctor_notifier_presence_never_prints_values(settings):
    secret = "my-private-ntfy-topic-xyz"
    assert OK in levels(probe_checks(settings), "push notifier is off")
    settings.notifier_type, settings.notifier_target = "ntfy", secret
    checks = probe_checks(settings)
    assert OK in levels(checks, "push notifier is configured")
    assert secret not in format_report(checks)
    settings.notifier_target = "x"
    assert WARN in levels(probe_checks(settings), "target is invalid")
    settings.notifier_target = ""
    assert WARN in levels(probe_checks(settings), "no target")
    # the env var counts, and is not printed either
    checks = probe_checks(settings, env={"CORTEX_NOTIFY_TARGET": secret})
    assert OK in levels(checks, "push notifier is configured") and secret not in format_report(checks)


def test_doctor_totp_configured_or_not(settings):
    from agent import totp
    assert WARN in levels(probe_checks(settings), "TOTP is not configured")
    settings.sms_mode = "totp"
    assert WARN in levels(probe_checks(settings), "secret/gateway missing")
    totp.save_secret(settings.data_dir, totp.new_secret())
    checks = probe_checks(settings)
    assert OK in levels(checks, "TOTP secret is configured")
    assert OK in levels(checks, "replay protected")


def test_doctor_critical_action_validation(settings):
    settings.critical_action = "shutdown"
    assert WARN in levels(probe_checks(settings), "critical_action is invalid")
    settings.critical_action = "hibernate"
    assert OK in levels(probe_checks(settings), "never shutdown")


def test_doctor_screenshots_folder_exists_or_not(settings):
    assert OK in levels(probe_checks(settings), "does not exist yet")     # by design: made on first use
    settings.screenshots_dir.mkdir(parents=True)
    assert OK in levels(probe_checks(settings), "screenshots folder exists")


# ----------------------------------------------------------- export-audit
def test_export_audit_writes_redacted_csv(engine, settings, tmp_path, capsys):
    import csv
    engine.audit.log("device:phone", "http", "lock", {"token": "SECRETTOKEN", "pin": "4821"},
                     "ok", "Authorization: Bearer abc123SECRET and sk-ant-api03-ZZZ")
    engine.audit.log("evil", "http", "x", {}, "ok", "=HYPERLINK(\"http://evil\")")
    import time as _t
    with engine.db.conn() as c:     # an entry older than the window
        c.execute("INSERT INTO audit_log (ts, actor, via, action, params, status, detail)"
                  " VALUES (?, 'old', 'http', 'old', '{}', 'ok', 'old')", (_t.time() - 30 * 86400,))
    rc = main(["--data-dir", str(settings.data_dir), "export-audit", "--days", "7"])
    assert rc == 0
    files_ = list(settings.data_dir.glob("audit-*.csv"))
    assert len(files_) == 1
    raw = files_[0].read_text(encoding="utf-8-sig")
    for secret in ("SECRETTOKEN", "4821", "abc123SECRET", "sk-ant-api03"):
        assert secret not in raw
    rows = list(csv.reader(raw.splitlines()))
    assert rows[0][0] == "time" and len(rows) == 3          # header + 2 recent
    assert not any(r[1] == "old" for r in rows)
    assert all(not cell.startswith("=") for r in rows for cell in r)   # no formula injection
