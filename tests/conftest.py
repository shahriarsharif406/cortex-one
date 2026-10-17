import threading
from pathlib import Path

import pytest

from agent.actions import Context
from agent.config import Settings
from agent.engine import Engine
from agent.security import hash_secret


class FakeRunner:
    """Records commands instead of running them."""

    def __init__(self, code: int = 0, out: str = ""):
        self.calls: list[list[str]] = []
        self.code, self.out = code, out

    def __call__(self, cmd, timeout=60):
        self.calls.append(list(cmd))
        return self.code, self.out


@pytest.fixture
def files(tmp_path) -> Path:
    root = tmp_path / "files"
    (root / "sub").mkdir(parents=True)
    (root / "report_2026.pdf").write_text("pdf")
    (root / "sub" / "notes.txt").write_text("hello")
    return root


@pytest.fixture
def settings(tmp_path, files) -> Settings:
    s = Settings(data_dir=tmp_path / "data")
    s.allowed_roots = [files]
    s.allowed_apps = {"notepad": ["notepad.exe"]}
    s.approved_scripts = {"backup": ["powershell", "-File", "backup.ps1"]}
    s.shutdown_delay_seconds = 30
    s.sms_allowed_numbers = ["+8801711111111"]
    s.sms_pin_hash = hash_secret("4821", iterations=1000)
    s.gateway_secret_hash = hash_secret("gw-secret", iterations=1000)
    s.allowed_domains = ["example.com", "docs.example.org"]
    s.screenshots_dir = files / "Screenshots"
    log_dir = tmp_path / "outside-logs"          # logs need not live in allowed_roots
    log_dir.mkdir()
    (log_dir / "coder.log").write_text("line1\nline2\nline3\n", encoding="utf-8")
    s.allowed_logs = {"coder": str(log_dir / "coder.log")}
    s.watched_programs = ["claude", "node"]
    return s


@pytest.fixture
def runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture
def launched() -> list:
    return []


@pytest.fixture
def opened() -> list:
    return []


@pytest.fixture
def engine(settings, runner, launched, opened) -> Engine:
    def fake_screenshot(path):
        Path(path).write_bytes(b"\x89PNG\r\n\x1a\nfake")

    ctx = Context(settings=settings, runner=runner, system="Windows",
                  launcher=lambda cmd: launched.append(cmd),
                  stop_event=threading.Event(),
                  screenshotter=fake_screenshot, url_opener=opened.append)
    eng = Engine(settings, ctx)
    eng.battery_provider = lambda: None       # never read the real battery in tests
    return eng


@pytest.fixture(autouse=True)
def _no_real_system_probes(monkeypatch):
    """Tests never ask Windows (powercfg) or the real interfaces; explicit fakes only."""
    from agent import wakeinfo

    monkeypatch.setattr(wakeinfo, "default_runner", lambda cmd, timeout=15: (-1, ""))
    monkeypatch.setattr(wakeinfo, "adapters", lambda: [])
