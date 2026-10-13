"""HTTP API for the phone app (and the SMS gateway)."""
from __future__ import annotations

import hmac
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field

from .actions import REGISTRY
from .ai import MAX_INSTRUCTION_LEN, AIUnavailable, Orchestrator
from .config import Settings
from .engine import Engine
from .security import Device, PairingLocked, RateLimiter, verify_secret
from .sms import SmsHandler


class PairRequest(BaseModel):
    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    device_name: str = Field(default="phone", max_length=60)


class ActionRequest(BaseModel):
    params: dict[str, Any] = Field(default_factory=dict)
    confirm_token: str | None = Field(default=None, max_length=64)


class AITaskRequest(BaseModel):
    instruction: str = Field(min_length=1, max_length=MAX_INSTRUCTION_LEN)


class SmsInbound(BaseModel):
    sender: str = Field(max_length=32, alias="from")
    text: str = Field(max_length=500)

    model_config = {"populate_by_name": True}


def create_app(settings: Settings | None = None,
               engine: Engine | None = None,
               ai_client=None) -> FastAPI:
    settings = settings or Settings.load()
    engine = engine or Engine(settings)
    sms = SmsHandler(engine)
    ai = Orchestrator(engine, client=ai_client)
    ai_limiter = RateLimiter(settings.ai_requests_per_minute)
    app = FastAPI(title="Cortex One Agent", docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.engine = engine

    def current_device(authorization: str | None = Header(default=None)) -> Device:
        token = None
        if authorization and authorization.lower().startswith("bearer "):
            token = authorization[7:].strip()
        device = engine.pairing.authenticate(token)
        if device is None:
            raise HTTPException(401, "Not authorised.")
        if not engine.limiter.allow(f"device:{device.id}"):
            raise HTTPException(429, "Too many requests. Slow down.")
        return device

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/pair")
    def pair(body: PairRequest, request: Request) -> dict[str, str]:
        client = request.client.host if request.client else "unknown"
        try:
            token = engine.pairing.pair(body.code, body.device_name)
        except PairingLocked:
            engine.audit.log(f"client:{client}", "http", "pair", {}, "rejected",
                             "pairing locked")
            raise HTTPException(429, "Pairing is temporarily locked.")
        if token is None:
            engine.audit.log(f"client:{client}", "http", "pair", {}, "rejected",
                             "bad or expired code")
            raise HTTPException(403, "Invalid or expired pairing code.")
        engine.audit.log(f"client:{client}", "http", "pair", {}, "ok",
                         f"paired '{body.device_name}'")
        return {"token": token}

    @app.get("/actions")
    def list_actions(device: Device = Depends(current_device)) -> list[dict]:
        return [{"name": s.name, "description": s.description, "risk": s.risk,
                 "params": list(s.params)} for s in REGISTRY.values()]

    @app.post("/actions/{name}")
    def run_action(name: str, body: ActionRequest,
                   device: Device = Depends(current_device)) -> dict[str, Any]:
        spec = REGISTRY.get(name)
        if spec is None:
            raise HTTPException(404, "Unknown action.")
        actor = f"device:{device.name}"
        if spec.risk == "high":
            if not body.confirm_token:
                token = engine.confirmations.issue(device.id, name, body.params)
                engine.audit.log(actor, "http", name, body.params, "pending",
                                 "confirmation requested")
                return {"status": "confirmation_required",
                        "confirm_token": token,
                        "expires_in": settings.confirm_ttl_seconds,
                        "message": f"Confirm '{name}' to continue."}
            if not engine.confirmations.consume(body.confirm_token, device.id,
                                                name, body.params):
                engine.audit.log(actor, "http", name, body.params, "rejected",
                                 "bad or expired confirmation")
                raise HTTPException(403, "Confirmation is invalid or expired.")
        result = engine.run(name, body.params, actor=actor, via="http")
        return {"status": "ok" if result.ok else "failed",
                "message": result.message, "data": result.data}

    @app.post("/emergency-stop")
    def emergency_stop(device: Device = Depends(current_device)) -> dict[str, Any]:
        result = engine.run("emergency_stop", {}, actor=f"device:{device.name}",
                            via="http")
        return {"status": "ok", "message": result.message}

    @app.post("/ai/tasks")
    def ai_task(body: AITaskRequest,
                device: Device = Depends(current_device)) -> dict[str, Any]:
        if not ai_limiter.allow(f"ai:{device.id}"):
            raise HTTPException(429, "Too many AI requests. Wait a minute.")
        try:
            result = ai.run(body.instruction, device.id, device.name)
        except AIUnavailable as exc:
            raise HTTPException(503, str(exc))
        return {"status": "ok" if result.ok else "stopped",
                "reply": result.reply,
                "steps": result.steps,
                "pending_confirmations": result.pending_confirmations,
                "tokens_used": result.tokens_used,
                "stopped_reason": result.stopped_reason}

    @app.get("/ai/usage")
    def ai_usage(device: Device = Depends(current_device)) -> dict[str, int]:
        return ai.usage_today()

    @app.get("/audit")
    def audit(limit: int = 50,
              device: Device = Depends(current_device)) -> list[dict]:
        return engine.audit.recent(limit)

    @app.post("/sms/inbound")
    def sms_inbound(body: SmsInbound,
                    x_gateway_secret: str | None = Header(default=None)) -> dict:
        stored = settings.gateway_secret_hash
        if not stored or not x_gateway_secret or not verify_secret(
                x_gateway_secret, stored):
            raise HTTPException(401, "Not authorised.")
        reply = sms.handle(body.sender, body.text)
        return {"reply": reply}

    return app
