"""HTTP API for the phone app (and the SMS gateway)."""
from __future__ import annotations

import hmac
import secrets
import threading
import time
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import __version__, screenshots
from .actions import REGISTRY, ActionError, validate_params
from .ai import (MAX_INSTRUCTION_LEN, AIUnavailable, AITask, AITaskResult,
                 Orchestrator, capabilities)
from .config import Settings
from .images import MAX_B64_CHARS, MAX_IMAGES, ImageError, validate_images
from .engine import Engine
from .security import (Device, LockoutTracker, PairingLocked, RateLimiter,
                       TooManyPending, verify_secret)
from .sms import SmsHandler


class PairRequest(BaseModel):
    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    device_name: str = Field(default="phone", max_length=60)


class ActionRequest(BaseModel):
    params: dict[str, Any] = Field(default_factory=dict)
    confirm_token: str | None = Field(default=None, max_length=64)


class ImageIn(BaseModel):
    model_config = {"extra": "forbid"}
    media_type: str = Field(max_length=20)
    data: str = Field(max_length=MAX_B64_CHARS)


class AITaskRequest(BaseModel):
    instruction: str = Field(min_length=1, max_length=MAX_INSTRUCTION_LEN)
    # up to 3 JPEG/PNG pictures, base64. The phone shrinks them and strips EXIF first; the agent
    # re-checks everything and refuses rather than "fixes".
    images: list[ImageIn] = Field(default_factory=list, max_length=MAX_IMAGES)
    # wait=true (default): answer when the task is done. wait=false: answer at
    # once with a job id and let the phone poll GET /ai/tasks/{id}.
    wait: bool = True


class ConfirmRequest(BaseModel):
    confirm_token: str = Field(min_length=1, max_length=64)


MAX_JOBS = 20


class Job:
    def __init__(self, device_id: int, task: AITask):
        self.id = secrets.token_urlsafe(9)
        self.device_id = device_id
        self.task = task
        self.status = "running"      # running | ok | stopped | error
        self.error = ""
        self.created = time.time()


def task_payload(result: AITaskResult) -> dict[str, Any]:
    return {"status": "ok" if result.ok else "stopped",
            "reply": result.reply,
            "steps": list(result.steps),
            "pending_confirmations": list(result.pending_confirmations),
            "tokens_used": result.tokens_used,
            "stopped_reason": result.stopped_reason,
            "model": result.model, "fallback": result.fallback}


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
    # /sms/inbound is unauthenticated until the secret is checked, and checking costs
    # a PBKDF2 run: throttle and lock out per client address BEFORE doing it.
    sms_limiter = RateLimiter(30)
    sms_lockout = LockoutTracker(5, 300)
    app = FastAPI(title="Cortex One Agent", docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.engine = engine

    MAX_TASK_BODY = 3 * MAX_B64_CHARS + 16_000          # three pictures plus the text

    @app.middleware("http")
    async def cap_ai_body(request: Request, call_next):
        """Refuse an oversized or length-less POST /ai/tasks BEFORE the body is read into memory."""
        if request.method == "POST" and request.url.path == "/ai/tasks":
            length = request.headers.get("content-length", "")
            if not length.isdigit():
                return JSONResponse(status_code=411, content={"detail": "Content-Length is required."})
            if int(length) > MAX_TASK_BODY:
                return JSONResponse(status_code=413, content={"detail": "The request is too large."})
        return await call_next(request)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_request: Request, exc: RequestValidationError) -> JSONResponse:
        # FastAPI's default body echoes the rejected input back; keep only where and why.
        return JSONResponse(status_code=422, content={"detail": [
            {"loc": list(e.get("loc", ())), "msg": str(e.get("msg", "invalid"))}
            for e in exc.errors()]})

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

    jobs: dict[str, Job] = {}
    jobs_lock = threading.Lock()

    def describe(action: str, params: dict[str, Any]) -> dict[str, Any]:
        """Plain-language description so the phone can show exactly what will run."""
        if action == "run_script":
            cmd = settings.approved_scripts.get(params.get("name", ""), [])
            return {"summary": f"Run the approved script '{params.get('name', '')}'",
                    "command": list(cmd)}
        if action == "shutdown":
            return {"summary": f"Shut down the laptop in {settings.shutdown_delay_seconds} seconds"}
        if action == "restart":
            return {"summary": f"Restart the laptop in {settings.shutdown_delay_seconds} seconds"}
        if action in ("coding_session_start", "coding_session_stop"):
            from .sessions import parse_projects

            project = parse_projects(settings)[0].get(str(params.get("name", "")).strip().lower())
            verb = "Start" if action.endswith("start") else "Stop"
            out = {"summary": f"{verb} the coding session '{params.get('name', '')}'"}
            if project is not None and verb == "Start":
                out["command"] = list(project.argv) + ["(in folder)", str(project.path)]
            return out
        if action == "gui_session_start":
            from .gui import GuiPolicy

            pol = GuiPolicy.from_settings(settings)
            return {"summary": f"Let the AI operate the mouse and keyboard for {params.get('minutes', '?')} "
                               f"minute(s), at most {pol.max_actions} actions, only while one of these apps "
                               f"is in front: {', '.join(sorted(pol.allowed_apps)) or 'none'}. You can stop "
                               "it any time; emergency stop ends it too. Unverified on a real screen."}
        if action == "remote_desktop_start":
            return {"summary": "Start the remote desktop helper (RustDesk). This makes the computer "
                               "reachable through it while it runs."}
        if action == "hibernate":
            return {"summary": "Hibernate the laptop now"}
        if action == "sleep":
            return {"summary": "Put the laptop to sleep now (wake it with a wake packet or its "
                               "power button)"}
        return {"summary": REGISTRY[action].description if action in REGISTRY else action}

    @app.get("/health")
    def health(request: Request) -> dict[str, Any]:
        """Unauthenticated and deliberately small: names, version, uptime, coarse battery,
        which of our addresses this request used, network state. No tokens, paths or MACs."""
        server = request.scope.get("server")
        return engine.health(server[0] if server else None)

    @app.get("/network")
    def network(device: Device = Depends(current_device)) -> dict:
        """Network watchdog state and recent network alerts (read-only)."""
        return engine.net.snapshot()

    @app.post("/pair")
    def pair(body: PairRequest, request: Request) -> dict[str, str]:
        client = request.client.host if request.client else "unknown"
        try:
            token = engine.pairing.pair(body.code, body.device_name, client)
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
                 "params": list(s.params), "optional": list(s.optional)}
                for s in REGISTRY.values()]

    @app.post("/actions/{name}")
    def run_action(name: str, body: ActionRequest,
                   device: Device = Depends(current_device)) -> dict[str, Any]:
        spec = REGISTRY.get(name)
        if spec is None:
            raise HTTPException(404, "Unknown action.")
        actor = f"device:{device.name}"
        if spec.risk == "high":
            try:   # validate first: only clean, small params may be stored or audited
                clean = validate_params(spec, body.params)
            except ActionError as exc:
                engine.audit.log(actor, "http", name, {}, "denied", str(exc))
                raise HTTPException(400, str(exc))
            body.params = dict(clean)
            from .sessions import precheck_high

            problem = precheck_high(settings, name, body.params)
            if problem:   # never ask the owner to confirm something that cannot run
                engine.audit.log(actor, "http", name, body.params, "denied", problem)
                raise HTTPException(400, problem)
            if not body.confirm_token:
                try:
                    token = engine.confirmations.issue(device.id, name, body.params)
                except TooManyPending:
                    raise HTTPException(429, "Too many confirmations are waiting. Answer or wait.")
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
        # keys starting with "_" carry pictures meant for the AI only; never send them to a client
        data = {k: v for k, v in result.data.items() if not str(k).startswith("_")}
        return {"status": "ok" if result.ok else "failed",
                "message": result.message, "data": data}

    @app.post("/emergency-stop")
    def emergency_stop(device: Device = Depends(current_device)) -> dict[str, Any]:
        result = engine.run("emergency_stop", {}, actor=f"device:{device.name}",
                            via="http")
        return {"status": "ok", "message": result.message}

    @app.post("/ai/tasks")
    def ai_task(body: AITaskRequest, response: Response,
                device: Device = Depends(current_device)) -> dict[str, Any]:
        if not ai_limiter.allow(f"ai:{device.id}"):
            raise HTTPException(429, "Too many AI requests. Wait a minute.")
        try:
            images = validate_images([i.model_dump() for i in body.images])
        except ImageError as exc:
            engine.audit.log(f"device:{device.name}", "http", "ai_task", {"images": len(body.images)},
                             "rejected", str(exc))
            raise HTTPException(400, str(exc))
        try:
            task = ai.begin(body.instruction, device.id, device.name, images)
        except AIUnavailable as exc:
            raise HTTPException(503, str(exc))
        if body.wait:
            return task_payload(ai.finish(task))
        job = Job(device.id, task)
        with jobs_lock:
            if len(jobs) >= MAX_JOBS:  # drop the oldest finished jobs
                for old in sorted((j for j in jobs.values() if j.status != "running"),
                                  key=lambda j: j.created)[:len(jobs) - MAX_JOBS + 1]:
                    del jobs[old.id]
            jobs[job.id] = job

        def work() -> None:
            try:
                ai.finish(task)
                job.status = "ok" if task.result.ok else "stopped"
            except Exception as exc:  # never leak details to the phone
                engine.audit.log(task.actor, "ai", "ai_task", {}, "error",
                                 f"{type(exc).__name__}")
                job.error = "The AI task failed unexpectedly. See the audit log."
                job.status = "error"

        threading.Thread(target=work, name=f"ai-job-{job.id}", daemon=True).start()
        response.status_code = 202
        return {"id": job.id, "status": "running"}

    @app.get("/ai/tasks/{job_id}")
    def ai_task_status(job_id: str, device: Device = Depends(current_device)) -> dict[str, Any]:
        with jobs_lock:
            job = jobs.get(job_id)
        if job is None or job.device_id != device.id:
            raise HTTPException(404, "No such task.")
        out = task_payload(job.task.result)
        out["id"] = job.id
        if job.status == "running":
            out["status"] = "running"
        elif job.status == "error":
            out.update(status="error", reply=job.error, stopped_reason=job.error)
        return out

    @app.get("/capabilities")
    def get_capabilities(device: Device = Depends(current_device)) -> dict[str, list[str]]:
        """What the owner allowed (names/paths only; never hashes, tokens or commands)."""
        return capabilities(settings)

    @app.get("/ai/pending")
    def ai_pending(device: Device = Depends(current_device)) -> list[dict[str, Any]]:
        rows = engine.confirmations.list_pending(device.id, "ai")
        return [{**row, **describe(row["action"], row["params"])} for row in rows]

    @app.post("/ai/confirm")
    def ai_confirm(body: ConfirmRequest,
                   device: Device = Depends(current_device)) -> dict[str, Any]:
        actor = f"device:{device.name}"
        found = engine.confirmations.peek(body.confirm_token, device.id, "ai")
        if found is None:
            engine.audit.log(actor, "http", "ai_confirm", {}, "rejected",
                             "no such pending request")
            raise HTTPException(403, "Confirmation is invalid or expired.")
        action, params = found
        # consume() re-checks the binding (device, action, params) and makes it single use
        if not engine.confirmations.consume(body.confirm_token, device.id, action, params):
            engine.audit.log(actor, "http", action, params, "rejected",
                             "bad or expired confirmation")
            raise HTTPException(403, "Confirmation is invalid or expired.")
        result = engine.run(action, params, actor=actor, via="http")
        return {"status": "ok" if result.ok else "failed", "action": action,
                "message": result.message, "data": result.data}

    @app.post("/ai/cancel")
    def ai_cancel(body: ConfirmRequest,
                  device: Device = Depends(current_device)) -> dict[str, str]:
        if not engine.confirmations.discard(body.confirm_token, device.id, "ai"):
            raise HTTPException(404, "No such pending request.")
        engine.audit.log(f"device:{device.name}", "http", "ai_cancel", {}, "ok",
                         "pending request cancelled by the owner")
        return {"status": "cancelled"}

    @app.get("/ai/history")
    def ai_history(limit: int = 50, device: Device = Depends(current_device)) -> list[dict]:
        """The last AI tasks: time, first 200 characters of the instruction, steps, ok, tokens."""
        return ai.history(limit, device.id)

    @app.get("/ai/usage")
    def ai_usage(device: Device = Depends(current_device)) -> dict[str, int]:
        return ai.usage_today()

    @app.get("/screenshots")
    def screenshots_list(device: Device = Depends(current_device)) -> dict[str, Any]:
        """Names of the agent's own screenshots, newest first (view-only)."""
        try:
            return {"files": screenshots.list_screenshots(settings),
                    "compression": screenshots.pillow_available()}
        except screenshots.ScreenshotError as exc:
            raise HTTPException(exc.status, exc.message)

    @app.get("/screenshots/{name}")
    def screenshot_file(name: str, width: int | None = None, quality: str = "normal",
                        device: Device = Depends(current_device)) -> Response:
        try:
            # "low" / "normal" (data-saver); a plain number is the older JPEG-quality form
            q = int(quality) if quality.isascii() and quality.isdigit() else screenshots.parse_quality(quality)
            data, mime = screenshots.load_screenshot(settings, name, width, q)
        except screenshots.ScreenshotError as exc:
            raise HTTPException(exc.status, exc.message)
        except OSError:
            raise HTTPException(404, "No such screenshot.")
        engine.audit.log(f"device:{device.name}", "http", "view_screenshot", {}, "ok",
                         f"{len(data)} bytes")
        return Response(content=data, media_type=mime,
                        headers={"Cache-Control": "no-store",
                                 "X-Content-Type-Options": "nosniff"})

    @app.get("/gui/session")
    def gui_session(device: Device = Depends(current_device)) -> dict:
        """State of the supervised GUI session (time left, actions used, last actions). Read-only."""
        return engine.ctx.gui.snapshot()

    @app.get("/gui/shot/{name}")
    def gui_shot(name: str, device: Device = Depends(current_device)) -> Response:
        """A small picture the GUI session saved (strict file names only)."""
        found = engine.ctx.gui.shot_bytes(name)
        if found is None:
            raise HTTPException(404, "No such picture.")
        return Response(content=found[0], media_type=found[1],
                        headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})

    @app.get("/alerts")
    def alerts(limit: int = 20, device: Device = Depends(current_device)) -> list[dict]:
        """Recent power / battery alerts from the watcher (read-only)."""
        return engine.alerts.recent(limit, scope="power")

    @app.get("/watch")
    def watch(device: Device = Depends(current_device)) -> dict:
        """Coding-agent watch rules with their status and recent rule alerts (read-only)."""
        return engine.watch.snapshot()

    @app.get("/audit")
    def audit(limit: int = 50,
              device: Device = Depends(current_device)) -> list[dict]:
        return engine.audit.recent(limit)

    @app.post("/sms/inbound")
    def sms_inbound(body: SmsInbound, request: Request,
                    x_gateway_secret: str | None = Header(default=None)) -> dict:
        client = request.client.host if request.client else "unknown"
        if sms_lockout.is_locked(client) or not sms_limiter.allow(client):
            raise HTTPException(429, "Too many requests.")
        stored = settings.gateway_secret_hash
        if not stored or not x_gateway_secret or not verify_secret(
                x_gateway_secret, stored):
            sms_lockout.record_failure(client)
            raise HTTPException(401, "Not authorised.")
        sms_lockout.reset(client)
        reply = sms.handle(body.sender, body.text)
        return {"reply": reply}

    return app
