"""File logging with rotation. Secrets are scrubbed before they are written."""
from __future__ import annotations

import logging
import re
from logging.handlers import RotatingFileHandler

from .config import Settings

_PATTERNS = [
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]+"), "sk-ant-***"),
    (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9_\-\.=]+"), r"\1***"),
    (re.compile(r"(?i)(x-gateway-secret\W+)[^\s\"']+"), r"\1***"),
    (re.compile(r"(?i)(\"?(?:token|pin|secret|password|confirm_token)\"?\s*[:=]\s*\"?)[^\s\",}]+"),
     r"\1***"),
]


def scrub(text: str) -> str:
    for pattern, repl in _PATTERNS:
        text = pattern.sub(repl, text)
    return text


class RedactingFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = scrub(record.getMessage())
        record.args = None
        return True


def setup_logging(settings: Settings) -> logging.Handler:
    """Send agent and uvicorn logs to <data_dir>/logs/agent.log (rotating)."""
    settings.logs_dir.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(
        settings.logs_dir / "agent.log", maxBytes=settings.log_max_bytes,
        backupCount=settings.log_backups, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    handler.addFilter(RedactingFilter())
    # Root only: uvicorn and "cortex" loggers propagate to it (log_config=None),
    # so attaching to the children as well would write every line several times.
    root = logging.getLogger()
    root.handlers = [h for h in root.handlers if not isinstance(h, RotatingFileHandler)]
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    return handler
