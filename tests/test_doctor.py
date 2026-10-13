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
    assert OK in levels(run_checks(settings, env={}), "SMS is set up")
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
