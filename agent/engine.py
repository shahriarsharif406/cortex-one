"""One place that runs actions, so REST, SMS and the CLI share the same
validation, logging and error handling."""
from __future__ import annotations

from typing import Any

from .actions import (REGISTRY, ActionError, ActionResult, Context,
                      validate_params)
from .audit import AuditLog
from .config import Settings
from .db import Database
from .security import ConfirmationStore, PairingManager, RateLimiter


class Engine:
    def __init__(self, settings: Settings, context: Context | None = None):
        self.settings = settings
        self.db = Database(settings.db_path)
        self.audit = AuditLog(self.db)
        self.pairing = PairingManager(self.db, settings)
        self.ctx = context or Context(settings=settings)
        self.limiter = RateLimiter(settings.requests_per_minute)
        self.confirmations = ConfirmationStore(settings.confirm_ttl_seconds)

    def run(self, action: str, params: dict[str, Any], actor: str,
            via: str) -> ActionResult:
        """Execute an allowlisted action. Never raises for expected errors."""
        spec = REGISTRY.get(action)
        if spec is None:
            self.audit.log(actor, via, action, params, "rejected", "unknown action")
            return ActionResult(False, "Unknown action.")
        try:
            clean = validate_params(spec, params)
            result = spec.handler(self.ctx, clean)
        except ActionError as exc:
            self.audit.log(actor, via, action, params, "denied", str(exc))
            return ActionResult(False, str(exc))
        except Exception as exc:  # never leak internals to the phone
            self.audit.log(actor, via, action, params, "error",
                           f"{type(exc).__name__}: {exc}")
            return ActionResult(False, "The action failed unexpectedly. See the audit log.")
        self.audit.log(actor, via, action, params,
                       "ok" if result.ok else "failed", result.message)
        return result
