"""Settings for the Cortex One Windows agent.

Everything security-relevant is opt-in: file access is limited to
``allowed_roots``, apps to ``allowed_apps`` and scripts to
``approved_scripts``. Secrets (SMS PIN, gateway secret) are stored only as
salted hashes.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path


def default_data_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "CortexOne"
    return Path.home() / ".cortex-one"


def _default_roots() -> list[Path]:
    home = Path.home()
    return [home / "Downloads", home / "Documents"]


def _default_apps() -> dict[str, list[str]]:
    return {
        "notepad": ["notepad.exe"],
        "calculator": ["calc.exe"],
        "explorer": ["explorer.exe"],
    }


@dataclass
class Settings:
    data_dir: Path = field(default_factory=default_data_dir)
    # Bind to loopback by default. For phone access, set this to the laptop's
    # Tailscale IP (never 0.0.0.0 on a public network).
    host: str = "127.0.0.1"
    port: int = 8765
    allowed_roots: list[Path] = field(default_factory=_default_roots)
    allowed_apps: dict[str, list[str]] = field(default_factory=_default_apps)
    approved_scripts: dict[str, list[str]] = field(default_factory=dict)
    shutdown_delay_seconds: int = 30
    requests_per_minute: int = 60
    pairing_ttl_seconds: int = 300
    confirm_ttl_seconds: int = 60
    max_pair_failures: int = 5
    pair_lockout_seconds: int = 300
    sms_allowed_numbers: list[str] = field(default_factory=list)
    sms_pin_hash: str = ""
    sms_max_failures: int = 3
    sms_lockout_seconds: int = 900
    gateway_secret_hash: str = ""
    # AI operator (Anthropic). The API key is read ONLY from the
    # ANTHROPIC_API_KEY environment variable, never from this file.
    ai_model: str = "claude-sonnet-5-5"
    ai_max_steps: int = 8
    ai_max_output_tokens: int = 1024
    ai_daily_token_cap: int = 200_000
    ai_requests_per_minute: int = 6
    ai_timeout_seconds: float = 30.0
    # Phase 2 allowlists. Empty means the capability is off.
    allowed_domains: list[str] = field(default_factory=list)      # open_url
    allowed_logs: dict[str, str] = field(default_factory=dict)    # tail_log: short name -> file
    watched_programs: list[str] = field(default_factory=list)     # agent_watch: e.g. ["claude", "node"]
    # take_screenshot saves here; it must be inside allowed_roots.
    screenshots_dir: Path = field(
        default_factory=lambda: Path.home() / "Documents" / "CortexOne-Screenshots")
    log_max_bytes: int = 1_000_000
    log_backups: int = 3

    @property
    def db_path(self) -> Path:
        return self.data_dir / "cortex.db"

    @property
    def config_path(self) -> Path:
        return self.data_dir / "config.json"

    @classmethod
    def load(cls, data_dir: Path | None = None) -> "Settings":
        s = cls(data_dir=Path(data_dir) if data_dir else default_data_dir())
        if s.config_path.exists():
            raw = json.loads(s.config_path.read_text(encoding="utf-8"))
            for key, value in raw.items():
                if key == "data_dir" or not hasattr(s, key):
                    continue
                if key == "allowed_roots":
                    value = [Path(p) for p in value]
                elif key == "screenshots_dir":
                    value = Path(value)
                setattr(s, key, value)
        return s

    @property
    def logs_dir(self) -> Path:
        return self.data_dir / "logs"

    def save(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        raw = asdict(self)
        raw.pop("data_dir")
        raw["allowed_roots"] = [str(p) for p in self.allowed_roots]
        raw["screenshots_dir"] = str(self.screenshots_dir)
        self.config_path.write_text(
            json.dumps(raw, indent=2, ensure_ascii=False), encoding="utf-8"
        )
