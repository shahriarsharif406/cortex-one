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
    # Several bind addresses (loopback, Tailscale 100.64.0.0/10, private LAN). When
    # set it replaces ``host``. Validated by agent/netbind.py; never 0.0.0.0.
    hosts: list[str] = field(default_factory=list)
    port: int = 8765
    # Shown to the phone. "" = the Windows computer name.
    computer_name: str = ""
    allowed_roots: list[Path] = field(default_factory=_default_roots)
    allowed_apps: dict[str, list[str]] = field(default_factory=_default_apps)
    approved_scripts: dict[str, list[str]] = field(default_factory=dict)
    shutdown_delay_seconds: int = 30
    requests_per_minute: int = 60
    pairing_ttl_seconds: int = 300
    # How long a phone token lives, in days, counted from pairing. 0 = no expiry (default).
    token_ttl_days: int = 0
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
    # "anthropic" (default) or "local" (a model on THIS computer, read-only tools only).
    ai_provider: str = "anthropic"
    # Offline fallback: when the cloud call fails with a NETWORK error, answer with the local
    # model using only read-only tools. Off by default. Endpoint must be http://127.0.0.1:PORT.
    ai_fallback_to_local: bool = False
    ai_local_endpoint: str = ""
    ai_local_model: str = ""
    ai_local_timeout_seconds: float = 60.0
    ai_max_steps: int = 8
    ai_max_output_tokens: int = 1024
    ai_daily_token_cap: int = 200_000
    ai_requests_per_minute: int = 6
    ai_timeout_seconds: float = 30.0
    # Pictures stay in the conversation, so they are paid for on every step: worst case
    # (estimated image tokens x ai_max_steps) must stay under this per task.
    ai_image_task_token_cap: int = 60_000
    # While a GUI session is active the AI gets the GUI tools with stricter limits: at most
    # this many model steps and this many tokens per task, and one GUI action per model turn.
    ai_gui_max_steps: int = 20
    ai_gui_task_token_cap: int = 120_000
    # Cost estimate for `ai-usage`. YOU set the prices (USD per million tokens);
    # nothing is hard-coded. 0 = not set.
    ai_price_per_mtok_input: float = 0.0
    ai_price_per_mtok_output: float = 0.0
    # Phase 2 allowlists. Empty means the capability is off.
    allowed_domains: list[str] = field(default_factory=list)      # open_url
    allowed_logs: dict[str, str] = field(default_factory=dict)    # tail_log: short name -> file
    watched_programs: list[str] = field(default_factory=list)     # agent_watch: e.g. ["claude", "node"]
    # take_screenshot saves here; it must be inside allowed_roots.
    screenshots_dir: Path = field(
        default_factory=lambda: Path.home() / "Documents" / "CortexOne-Screenshots")
    log_max_bytes: int = 1_000_000
    log_backups: int = 3
    # Screenshots: the newest N are kept, older agent-made ones are deleted.
    screenshot_keep: int = 20
    # Power-cut / battery watcher (psutil battery data only; idle on desktops).
    power_watch: bool = True
    power_warn_percent: int = 30
    power_critical_percent: int = 10
    power_check_seconds: int = 30
    # Optional push. "" = off. "ntfy" (target = topic) or "webhook" (target = https URL).
    # Prefer the CORTEX_NOTIFY_TARGET environment variable over notifier_target:
    # an ntfy topic works like a password for who may read/post to it.
    notifier_type: str = ""
    notifier_target: str = ""
    # What the watcher may do at critical battery on battery power:
    # "none" | "hibernate" | "lock". Never "shutdown".
    critical_action: str = "none"
    # Coding-agent watcher: see agent/watch.py. Each rule is
    # {name, kind: process_exit|log_stalled|log_pattern, target, minutes, pattern}.
    watch_rules: list = field(default_factory=list)
    watch_check_seconds: int = 30
    watch_cooldown_seconds: int = 600
    # Computers THIS computer may wake with Wake-on-LAN: {name: {"mac": "AA:BB:CC:DD:EE:FF",
    # "broadcast": "192.168.1.255"}}. Empty = wake_computer is off.
    wake_targets: dict = field(default_factory=dict)
    # Coding sessions the OWNER defines: {name: {"path": folder inside allowed_roots,
    # "argv": [program, arg, ...]}}. The phone/AI only ever name a project (agent/sessions.py).
    coding_projects: dict = field(default_factory=dict)
    # Remote desktop helper (RustDesk): the process NAME to look for and the key in allowed_apps
    # used to start it. Its password and config files are never read.
    remote_desktop_process: str = "rustdesk"
    remote_desktop_app: str = "rustdesk"
    # Supervised GUI-agent mode (agent/gui.py). OFF by default. Keys: enabled (bool),
    # max_session_minutes (default 10), max_actions (default 60), allowed_apps (process names
    # that must be in front for any input), blocked_title_patterns (substrings), blocked_apps.
    gui_agent: dict = field(default_factory=dict)
    # Name of the SIM / USB-tether network adapter (doctor checks that it exists).
    backup_adapter_name: str = ""
    # Network watchdog (report only). Empty targets = the built-in two. "host:port".
    net_watch: bool = True
    net_check_seconds: int = 30
    net_watch_targets: list[str] = field(default_factory=list)
    # SMS authentication: "pin" (static PIN, no replay protection) or "totp".
    sms_mode: str = "pin"

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
