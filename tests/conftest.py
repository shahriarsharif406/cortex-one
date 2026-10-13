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
    return s


@pytest.fixture
def runner() -> FakeRunner:
    return FakeRunner()


@pytest.fixture
def launched() -> list:
    return []


@pytest.fixture
def engine(settings, runner, launched) -> Engine:
    ctx = Context(settings=settings, runner=runner, system="Windows",
                  launcher=lambda cmd: launched.append(cmd),
                  stop_event=threading.Event())
    return Engine(settings, ctx)
