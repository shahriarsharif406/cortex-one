"""One place that runs actions, so REST, SMS and the CLI share the same
validation, logging and error handling."""
from __future__ import annotations

from typing import Any

from .actions import (REGISTRY, ActionError, ActionResult, Context,
                      validate_params)
from .audit import AuditLog
from .config import Settings
from .db import Database
from .power import AlertStore, critical_threshold
from .watch import RuleWatcher
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
        self.alerts = AlertStore(self.db)
        self.watch = RuleWatcher(self)       # rule watcher; serve starts its thread

    # Channels that only trusted in-process code may use. HTTP, SMS, the AI and
    # the CLI pass their own fixed ``via``, so a client can never reach this.
    RESERVED_VIA = frozenset({"watcher"})
    WATCHER_ACTIONS = frozenset({"hibernate", "lock"})

    def run(self, action: str, params: dict[str, Any], actor: str,
            via: str) -> ActionResult:
        """Execute an allowlisted action. Never raises for expected errors."""
        if via in self.RESERVED_VIA:
            self.audit.log(actor, via, action, params, "rejected", "reserved channel")
            return ActionResult(False, "Not allowed.")
        spec = REGISTRY.get(action)
        if via == "ai" and spec is not None and spec.risk == "high":
            # defence in depth: the AI layer already refuses these; so does the engine
            self.audit.log(actor, via, action, params, "rejected", "high-risk action from the AI")
            return ActionResult(False, "The AI cannot run this action.")
        return self._execute(action, params, actor, via)

    def run_power_action(self, battery_percent: float | None,
                         plugged: bool | None) -> ActionResult | None:
        """The battery watcher's single escape hatch around the confirmation.

        Runs ``settings.critical_action`` (hibernate or lock, never shutdown)
        and ONLY when every condition is re-checked here: the configured action
        is on the short WATCHER_ACTIONS list, the laptop is on battery
        (``plugged is False``, not unknown) and the charge is at or below the
        critical threshold. Anything else returns None and does nothing.
        """
        action = (self.settings.critical_action or "none").strip().lower()
        if action not in self.WATCHER_ACTIONS:
            return None
        if plugged is not False or not isinstance(battery_percent, (int, float)):
            return None
        if battery_percent > critical_threshold(self.settings):
            return None
        return self._execute(action, {}, "watcher", "watcher")

    def _execute(self, action: str, params: dict[str, Any], actor: str,
                 via: str) -> ActionResult:
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
