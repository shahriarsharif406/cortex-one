"""Optional local-AI fallback (session 2, phase 8).

A local model (for example Ollama) listens on THIS computer only. It is used

* as the main provider if the owner sets ``ai_provider = "local"``, or
* as an offline fallback if ``ai_fallback_to_local`` is on and the cloud call fails with a
  NETWORK error (not for a bad key, no credit, rate limits ...).

It can only use a short read-only tool list (``LOCAL_TOOLS``): no high-risk request, no GUI, no
pictures, no files written, no apps opened. Its answers are marked with the model's name so the
owner always knows which model replied. Nothing here is installed or downloaded by Cortex One.

``LocalClient`` mimics the small part of the Anthropic client that the orchestrator uses
(``client.messages.create``), so all the existing safety code (registry, allowlists, untrusted
output fences, step caps, audit) applies unchanged.
"""
from __future__ import annotations

import ipaddress
import json
import urllib.error
import urllib.request
from types import SimpleNamespace as NS
from typing import Any
from urllib.parse import urlsplit

# The ONLY tools a local model may call. All are read-only and low-risk.
LOCAL_TOOLS = ("status", "system_info", "list_files", "list_processes", "power_capabilities")
MAX_RESPONSE_BYTES = 1_000_000
LOCAL_NOTE = """

You are a SMALL LOCAL model running offline on the owner's computer, used because the internet is unavailable. You have only read-only tools: status, system_info, list_files, list_processes, power_capabilities. You cannot shut down, restart, open apps, run scripts, use the screen or see pictures. If the owner asks for something else, say plainly that it needs the main assistant and the internet. Be short."""


class LocalAIError(Exception):
    """The local model could not be used. The message is safe to show."""


def check_local_endpoint(url: Any) -> str:
    """Return the base URL (http only, loopback only, no credentials, no path) or raise."""
    if not isinstance(url, str) or not url.strip() or not url.isascii():
        raise LocalAIError("ai_local_endpoint is not set to a plain http://127.0.0.1:PORT address.")
    try:
        parts = urlsplit(url.strip())
        port = parts.port
    except ValueError:
        raise LocalAIError("ai_local_endpoint is not a valid address.")
    host = (parts.hostname or "").lower()
    loopback = host == "localhost"
    if not loopback:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
    if (parts.scheme != "http" or not loopback or parts.username or parts.password
            or parts.path not in ("", "/") or parts.query or parts.fragment):
        raise LocalAIError("The local model must be on this computer: http://127.0.0.1:PORT "
                           "(no other host, no https, no login, no path).")
    return f"http://{host if ':' not in host else '[' + host + ']'}:{port or 11434}"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):      # a redirect could point somewhere that is not localhost
        return None


def _block(b: Any, key: str, default: Any = None) -> Any:
    return b.get(key, default) if isinstance(b, dict) else getattr(b, key, default)


def to_ollama_messages(system: str, messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Anthropic-style turns -> Ollama chat turns."""
    out: list[dict[str, Any]] = [{"role": "system", "content": system}]
    for m in messages:
        content = m.get("content")
        if isinstance(content, str):
            out.append({"role": m["role"], "content": content})
            continue
        if m["role"] == "assistant":
            texts, calls = [], []
            for b in content or []:
                if _block(b, "type") == "text":
                    texts.append(str(_block(b, "text", "")))
                elif _block(b, "type") == "tool_use":
                    calls.append({"function": {"name": _block(b, "name"), "arguments": _block(b, "input") or {}}})
            msg: dict[str, Any] = {"role": "assistant", "content": "\n".join(texts)}
            if calls:
                msg["tool_calls"] = calls
            out.append(msg)
        else:
            for b in content or []:
                if _block(b, "type") == "tool_result":
                    body = _block(b, "content", "")
                    if isinstance(body, list):          # a picture result never reaches the local model
                        body = "\n".join(str(_block(x, "text", "")) for x in body if _block(x, "type") == "text")
                    out.append({"role": "tool", "content": str(body)})
                elif _block(b, "type") == "text":
                    out.append({"role": "user", "content": str(_block(b, "text", ""))})
    return out


def to_ollama_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                              "parameters": t["input_schema"]}} for t in tools]


class LocalClient:
    """``client.messages.create(...)`` against a local Ollama-style ``/api/chat`` endpoint."""

    def __init__(self, endpoint: str, model: str, timeout: float = 60.0, opener=None):
        self.base = check_local_endpoint(endpoint)
        if not isinstance(model, str) or not model.strip() or len(model) > 80 or not model.isascii():
            raise LocalAIError("ai_local_model is not set.")
        self.model = model.strip()
        self.timeout = max(5.0, min(float(timeout), 300.0))
        self._open = opener or urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _NoRedirect).open      # never through a proxy
        self.messages = self
        self._ids = 0

    def create(self, *, model: str = "", max_tokens: int = 512, system: str = "",
               tools: list[dict[str, Any]] | None = None, messages: list[dict[str, Any]]) -> Any:
        # only the fixed read-only tools can be offered, whatever the caller passes
        tools = [t for t in (tools or []) if t.get("name") in LOCAL_TOOLS]
        payload = {"model": self.model, "stream": False,
                   "options": {"num_predict": int(max_tokens)},
                   "messages": to_ollama_messages(system, messages),
                   "tools": to_ollama_tools(tools)}
        req = urllib.request.Request(self.base + "/api/chat", data=json.dumps(payload).encode("utf-8"),
                                     method="POST", headers={"Content-Type": "application/json"})
        try:
            with self._open(req, timeout=self.timeout) as resp:
                raw = resp.read(MAX_RESPONSE_BYTES + 1)
        except (urllib.error.URLError, OSError, TimeoutError):
            raise LocalAIError("The local model is not reachable. Is it running?")
        if len(raw) > MAX_RESPONSE_BYTES:
            raise LocalAIError("The local model sent too much data.")
        try:
            data = json.loads(raw.decode("utf-8", "replace"))
            msg = data["message"]
            if not isinstance(msg, dict):
                raise TypeError("message must be an object")
        except (ValueError, KeyError, TypeError):
            raise LocalAIError("The local model gave an unreadable answer.")
        blocks: list[Any] = []
        text = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(text, str) and text.strip():
            blocks.append(NS(type="text", text=text))
        calls = msg.get("tool_calls") if isinstance(msg, dict) else None
        used_tools = False
        for call in (calls if isinstance(calls, list) else [])[:20]:
            if sum(1 for b in blocks if b.type == "tool_use") >= 4:
                break                                   # at most four valid calls per answer
            fn = call.get("function") if isinstance(call, dict) else None
            if not isinstance(fn, dict) or not isinstance(fn.get("name"), str):
                continue
            args = fn.get("arguments")
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {}
            self._ids += 1
            blocks.append(NS(type="tool_use", id=f"local_{self._ids}", name=fn["name"],
                             input={str(k): v for k, v in (args if isinstance(args, dict) else {}).items()}))
            used_tools = True
        usage = NS(input_tokens=int(data.get("prompt_eval_count") or 0) if isinstance(data, dict) else 0,
                   output_tokens=int(data.get("eval_count") or 0) if isinstance(data, dict) else 0)
        return NS(content=blocks, stop_reason="tool_use" if used_tools else "end_turn", usage=usage)
