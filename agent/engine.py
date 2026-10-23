"""One place that runs actions, so REST, SMS and the CLI share the same
validation, logging and error handling."""
from __future__ import annotations

import json
import platform
import secrets
import time
from typing import Any

from .actions import (REGISTRY, ActionError, ActionResult, Context, safe_params,
                      validate_params)
from .audit import AuditLog
from .config import Settings
from .db import Database
from .netbind import classify_address
from .netwatch import NetWatcher
from .power import AlertStore, critical_threshold, psutil_battery
from .watch import RuleWatcher
from .security import (VIEWER_ACTIONS, ConfirmationStore, PairingManager,
                       RateLimiter)


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
        self.net = NetWatcher(self)          # network watchdog (report only)
        self.ctx.watch_snapshot = self.watch.snapshot
        self.ctx.session_exit_hook = self._session_exited
        self.notifier = None                 # serve sets a Notifier (optional push)
        self.started_at = time.time()
        self.battery_provider = psutil_battery

    # Channels that only trusted in-process code may use. HTTP, SMS, the AI and
    # the CLI pass their own fixed ``via``, so a client can never reach this.
    RESERVED_VIA = frozenset({"watcher", "schedule"})
    WATCHER_ACTIONS = frozenset({"hibernate", "lock"})

    def run(self, action: str, params: dict[str, Any], actor: str,
            via: str, role: str = "owner") -> ActionResult:
        """Execute an allowlisted action. Never raises for expected errors.

        ``role`` is the role of the phone that asked ("owner" or "viewer"). A viewer may only
        run VIEWER_ACTIONS: this is the second layer behind the HTTP check."""
        if role != "owner" and action not in VIEWER_ACTIONS:
            self.audit.log(actor, via, action, safe_params(action, params), "rejected", "viewer role")
            return ActionResult(False, "This phone has the viewer role: it can only look.")
        if via in self.RESERVED_VIA:
            self.audit.log(actor, via, action, params, "rejected", "reserved channel")
            return ActionResult(False, "Not allowed.")
        spec = REGISTRY.get(action)
        if via == "ai" and spec is not None and spec.risk == "high":
            # defence in depth: the AI layer already refuses these; so does the engine
            self.audit.log(actor, via, action, params, "rejected", "high-risk action from the AI")
            return ActionResult(False, "The AI cannot run this action.")
        return self._execute(action, params, actor, via)

    # Actions after which the computer is expected to go away. The agent remembers the
    # last one so the phone can tell "sleeping" from "offline" when it comes back.
    POWER_ACTIONS = frozenset({"sleep", "hibernate", "shutdown", "restart"})

    def _session_exited(self, name: str, code: int | None) -> None:
        """A coding session this agent started has ended: a fixed sentence goes to the alerts
        table and the optional push (never program output)."""
        message = f"Coding session '{name}' ended (exit code {code})"
        self.alerts.add("watch_session_exit", None, None, message)
        self.audit.log("watcher", "sessions", "coding_session_exit", {"project": name}, "ok",
                       f"exit code {code}")
        if self.notifier is not None:
            try:
                self.notifier.notify(message, None, time.strftime("%H:%M"))
            except Exception:
                pass

    def computer_id(self) -> str:
        """A random id made once per installation (not derived from hardware)."""
        cid = self.db.kv_get("computer_id")
        if not cid:
            cid = secrets.token_hex(8)
            self.db.kv_set("computer_id", cid)
        return cid

    def computer_name(self) -> str:
        name = (self.settings.computer_name or "").strip() or platform.node()
        return "".join(ch for ch in name if ch.isprintable())[:60] or "computer"

    def last_power_request(self) -> dict[str, Any] | None:
        raw = self.db.kv_get("last_power_request")
        try:
            data = json.loads(raw) if raw else None
            if (isinstance(data, dict) and data.get("action") in self.POWER_ACTIONS
                    and isinstance(data.get("ts"), (int, float))):
                return {"action": data["action"], "age_seconds": max(0, round(time.time() - data["ts"]))}
        except ValueError:
            pass
        return None

    def health(self, link_address: str | None = None) -> dict[str, Any]:
        """The /health body. No secrets: names, versions, coarse numbers only."""
        from . import __version__

        try:
            battery = self.battery_provider()
        except Exception:
            battery = None
        hosts = self.configured_hosts
        link = None
        if link_address and link_address in hosts:
            link = {"address": link_address, "kind": classify_address(link_address)}
        return {
            "status": "ok", "version": __version__,
            "computer_id": self.computer_id(), "computer_name": self.computer_name(),
            "uptime_seconds": round(time.time() - self.started_at),
            "battery": None if battery is None else {
                "percent": round(battery.percent), "plugged": battery.plugged},
            "link": link,
            "network": {"state": self.net.state, "since": self.net.since},
            "last_power_request": self.last_power_request(),
        }

    @property
    def configured_hosts(self) -> list[str]:
        from .netbind import BindError, effective_hosts

        try:
            return effective_hosts(self.settings)
        except BindError:
            return []

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

    def run_scheduled(self, name: str, action: str, params: dict[str, Any]) -> ActionResult:
        """The scheduler's only way in. Re-checks that the action is low-risk and allowed
        for schedules; the channel ``schedule`` is reserved so no client can name it."""
        from .schedule import allowed_action

        if not allowed_action(action):
            self.audit.log("schedule", "schedule", action, {}, "rejected", "not schedulable")
            return ActionResult(False, "Not allowed.")
        return self._execute(action, params, f"schedule:{name}"[:60], "schedule")

    def _execute(self, action: str, params: dict[str, Any], actor: str,
                 via: str) -> ActionResult:
        spec = REGISTRY.get(action)
        if spec is None:
            self.audit.log(actor, via, action, safe_params(action, params), "rejected", "unknown action")
            return ActionResult(False, "Unknown action.")
        try:
            clean = validate_params(spec, params)
            result = spec.handler(self.ctx, clean)
        except ActionError as exc:
            self.audit.log(actor, via, action, safe_params(action, params), "denied", str(exc))
            return ActionResult(False, str(exc))
        except Exception as exc:  # never leak internals to the phone
            self.audit.log(actor, via, action, safe_params(action, params), "error",
                           f"{type(exc).__name__}: {exc}")
            return ActionResult(False, "The action failed unexpectedly. See the audit log.")
        self.audit.log(actor, via, action, safe_params(action, params),
                       "ok" if result.ok else "failed", result.message)
        if result.ok and action in self.POWER_ACTIONS:
            try:
                self.db.kv_set("last_power_request",
                               json.dumps({"action": action, "ts": time.time()}))
            except Exception:
                pass
        return result
