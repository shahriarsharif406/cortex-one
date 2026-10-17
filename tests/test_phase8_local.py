"""Session 2, phase 8: optional local-AI fallback (a fake local server; no model is installed)."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from fastapi.testclient import TestClient

from agent.ai import Orchestrator, build_tools, dry_run_text
from agent.doctor import run_checks
from agent.images import validate_images
from agent.localai import (LOCAL_TOOLS, LocalAIError, LocalClient, check_local_endpoint,
                           to_ollama_messages)
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use
from .test_phase5_images import item, png_bytes


# ------------------------------------------------------------- a fake local server
class FakeOllama:
    def __init__(self):
        self.requests = []
        self.script = []
        self.raw = None            # send these bytes instead (status, body, headers)
        owner = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append({"path": self.path, "body": body})
                if owner.raw is not None:
                    status, data, headers = owner.raw
                    self.send_response(status)
                    for k, v in headers.items():
                        self.send_header(k, v)
                    self.end_headers()
                    self.wfile.write(data)
                    return
                answer = owner.script.pop(0) if owner.script else {"message": {"role": "assistant", "content": "ok"}}
                data = json.dumps(answer).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def say(content, calls=None, inp=12, out=7):
    msg = {"role": "assistant", "content": content}
    if calls:
        msg["tool_calls"] = [{"function": {"name": n, "arguments": a}} for n, a in calls]
    return {"message": msg, "prompt_eval_count": inp, "eval_count": out}


@pytest.fixture
def ollama():
    srv = FakeOllama()
    yield srv
    srv.close()


@pytest.fixture
def local(engine, settings, ollama):
    settings.ai_local_endpoint = ollama.url
    settings.ai_local_model = "tiny-model:1b"
    return engine


class APIConnectionError(Exception):
    pass


class APITimeoutError(Exception):
    pass


class AuthenticationError(Exception):
    status_code = 401


class RateLimitError(Exception):
    status_code = 429


class Credit(Exception):
    status_code = 400
    message = "Your credit balance is too low"


def cloud_failing(exc):
    return FakeClient([exc])


def orc(engine, client=None):
    return Orchestrator(engine, client=client, today=lambda: "2026-10-17")


# ----------------------------------------------------------------------- endpoint
@pytest.mark.parametrize("url", ["http://127.0.0.1:11434", "http://localhost:11434", "http://127.0.0.1",
                                 "http://127.1.2.3:9", "http://[::1]:11434", "http://127.0.0.1:11434/"])
def test_loopback_http_endpoints_are_accepted(url):
    assert check_local_endpoint(url).startswith("http://")


@pytest.mark.parametrize("url", ["", None, 5, "http://example.com:11434", "http://192.168.1.5:11434",
                                 "http://100.64.0.1:11434", "https://127.0.0.1:11434", "http://0.0.0.0:11434",
                                 "http://user:pw@127.0.0.1:11434", "http://127.0.0.1:11434/api",
                                 "http://127.0.0.1:11434?x=1", "http://127.0.0.1:99999", "ftp://127.0.0.1",
                                 "http://127.0.0.1@evil.example", "http://localhost.evil.example:1", "127.0.0.1:11434"])
def test_other_endpoints_are_refused(url):
    with pytest.raises(LocalAIError):
        check_local_endpoint(url)


def test_model_name_is_required():
    with pytest.raises(LocalAIError):
        LocalClient("http://127.0.0.1:11434", "")
    with pytest.raises(LocalAIError):
        LocalClient("http://127.0.0.1:11434", "x" * 200)


# ----------------------------------------------------------------- local provider
def test_local_provider_answers_with_read_only_tools(engine, settings, local, ollama, monkeypatch):
    settings.ai_provider = "local"
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)           # no key needed
    ollama.script = [say("", [("system_info", {})]), say("Your CPU is idle.")]
    r = orc(engine).run("how is the laptop?", 1, "phone")
    assert r.ok and r.reply == "Your CPU is idle." and r.model == "tiny-model:1b" and not r.fallback
    first = ollama.requests[0]["body"]
    names = {t["function"]["name"] for t in first["tools"]}
    assert names == set(LOCAL_TOOLS)
    assert first["stream"] is False and first["model"] == "tiny-model:1b"
    assert "SMALL LOCAL model" in first["messages"][0]["content"]
    # the tool result goes back fenced as untrusted data
    tool_msg = [m for m in ollama.requests[1]["body"]["messages"] if m["role"] == "tool"][0]
    assert tool_msg["content"].startswith('<tool_output untrusted="true">')


def test_local_tools_are_only_the_fixed_read_only_list():
    tools = {t["name"] for t in build_tools(local=True)}
    assert tools == set(LOCAL_TOOLS)
    from agent.actions import REGISTRY
    assert all(REGISTRY[n].risk == "low" for n in LOCAL_TOOLS)
    assert not tools & {"shutdown", "restart", "hibernate", "sleep", "run_script", "open_app", "copy_file",
                        "make_folder", "open_url", "take_screenshot", "wake_computer", "emergency_stop",
                        "gui_session_start", "gui_click", "coding_session_start", "remote_desktop_start"}


@pytest.mark.parametrize("name,args", [
    ("shutdown", {}), ("restart", {}), ("hibernate", {}), ("sleep", {}), ("run_script", {"name": "backup"}),
    ("open_app", {"name": "notepad"}), ("copy_file", {"src": "a", "dst": "b"}), ("make_folder", {"path": "x"}),
    ("open_url", {"url": "https://example.com"}), ("take_screenshot", {}), ("wake_computer", {"name": "d"}),
    ("gui_session_start", {"minutes": "3"}), ("gui_click", {"x": "1", "y": "1"}), ("emergency_stop", {}),
    ("coding_session_start", {"name": "api"}), ("remote_desktop_start", {}), ("tail_log", {"name": "coder"}),
    ("find_files", {"root": "x", "query": "y"}), ("lock", {}), ("cancel_shutdown", {}), ("nope", {})])
def test_a_local_model_asking_for_anything_else_is_refused(engine, settings, local, ollama, runner, launched, opened, name, args):
    settings.ai_provider = "local"
    ollama.script = [say("", [(name, args)]), say("done")]
    r = orc(engine).run("do it", 1, "phone")
    assert not r.steps[0]["ok"]
    assert r.pending_confirmations == []              # not even a request for confirmation
    assert runner.calls == [] and launched == [] and opened == []


def test_local_provider_refuses_pictures(engine, settings, local):
    settings.ai_provider = "local"
    from agent.ai import AIUnavailable
    with pytest.raises(AIUnavailable, match="Pictures are not available"):
        orc(engine).begin("x", 1, "phone", validate_images([item(png_bytes())]))


def test_local_provider_without_a_valid_endpoint_says_so(engine, settings):
    settings.ai_provider = "local"
    settings.ai_local_endpoint = "http://example.com:1"
    settings.ai_local_model = "m"
    from agent.ai import AIUnavailable
    with pytest.raises(AIUnavailable, match="on this computer"):
        orc(engine).begin("x", 1, "phone")


def test_local_server_down_gives_a_plain_message(engine, settings, local, ollama):
    settings.ai_provider = "local"
    ollama.close()
    r = orc(engine).run("x", 1, "phone")
    assert not r.ok and "not reachable" in r.stopped_reason


def test_local_usage_is_not_counted_against_the_cloud_budget(engine, settings, local, ollama):
    settings.ai_provider = "local"
    ollama.script = [say("hi", inp=1000, out=500)]
    r = orc(engine).run("hi", 1, "phone")
    assert r.tokens_used == 1500
    assert orc(engine).usage_today()["total_tokens"] == 0


# ------------------------------------------------------------------------ fallback
def test_fallback_is_off_by_default(engine, settings, local, ollama):
    assert settings.ai_fallback_to_local is False
    r = orc(engine, cloud_failing(APIConnectionError("down"))).run("x", 1, "phone")
    assert not r.ok and "Could not reach the AI service" in r.stopped_reason
    assert ollama.requests == [] and not r.fallback


def test_a_network_error_falls_back_to_the_local_model(engine, settings, local, ollama):
    settings.ai_fallback_to_local = True
    ollama.script = [say("", [("status", {})]), say("The laptop is fine.")]
    r = orc(engine, cloud_failing(APIConnectionError("down"))).run("how is it?", 1, "phone")
    assert r.ok and r.fallback and r.model == "tiny-model:1b"
    assert r.reply.startswith("[Local model tiny-model:1b, offline and read-only]")
    assert "The laptop is fine." in r.reply
    assert [s["tool"] for s in r.steps] == ["status"]
    assert any(a["action"] == "ai_fallback" for a in engine.audit.recent(20))


def test_a_timeout_also_falls_back(engine, settings, local, ollama):
    settings.ai_fallback_to_local = True
    ollama.script = [say("local answer")]
    r = orc(engine, cloud_failing(APITimeoutError("slow"))).run("x", 1, "phone")
    assert r.ok and r.fallback


@pytest.mark.parametrize("exc", [AuthenticationError("bad key"), RateLimitError("slow down"), Credit("no credit"),
                                 ValueError("odd")])
def test_only_network_errors_trigger_the_fallback(engine, settings, local, ollama, exc):
    settings.ai_fallback_to_local = True
    r = orc(engine, cloud_failing(exc)).run("x", 1, "phone")
    assert not r.ok and not r.fallback and ollama.requests == []


def test_the_owner_is_told_which_model_answered_over_http(engine, settings, local, ollama):
    settings.ai_fallback_to_local = True
    ollama.script = [say("offline answer")]
    app = create_app(settings, engine, ai_client=cloud_failing(APIConnectionError("down")))
    http = TestClient(app)
    code = engine.pairing.create_code()
    tok = http.post("/pair", json={"code": code}).json()["token"]
    body = http.post("/ai/tasks", headers={"Authorization": f"Bearer {tok}"}, json={"instruction": "hi"}).json()
    assert body["fallback"] is True and body["model"] == "tiny-model:1b"
    assert body["reply"].startswith("[Local model tiny-model:1b")


def test_cloud_answers_carry_the_cloud_model_name(engine, settings):
    r = orc(engine, FakeClient([resp([text("hi")])])).run("x", 1, "phone")
    assert r.model == settings.ai_model and not r.fallback


def test_fallback_does_not_use_pictures_and_says_so(engine, settings, local, ollama):
    settings.ai_fallback_to_local = True
    ollama.script = [say("no pictures for me")]
    imgs = validate_images([item(png_bytes())])
    r = orc(engine, cloud_failing(APIConnectionError("down"))).run("what is this?", 1, "phone", imgs)
    assert "the pictures were not used" in r.reply
    sent = json.dumps(ollama.requests[0]["body"])
    assert "image" not in sent and "base64" not in sent


def test_fallback_that_cannot_run_keeps_the_cloud_message_and_says_why(engine, settings):
    settings.ai_fallback_to_local = True
    settings.ai_local_endpoint = ""
    r = orc(engine, cloud_failing(APIConnectionError("down"))).run("x", 1, "phone")
    assert not r.ok and "Could not reach the AI service" in r.stopped_reason
    assert "Local fallback is not available" in r.stopped_reason


def test_fallback_with_the_local_server_down(engine, settings, local, ollama):
    settings.ai_fallback_to_local = True
    ollama.close()
    r = orc(engine, cloud_failing(APIConnectionError("down"))).run("x", 1, "phone")
    assert not r.ok and "not reachable" in r.stopped_reason


def test_fallback_never_creates_a_confirmation_even_if_asked(engine, settings, local, ollama, runner):
    settings.ai_fallback_to_local = True
    ollama.script = [say("", [("shutdown", {}), ("run_script", {"name": "backup"})]), say("ok")]
    r = orc(engine, cloud_failing(APIConnectionError("down"))).run("shut down", 1, "phone")
    assert r.pending_confirmations == [] and runner.calls == []


def test_fallback_tasks_are_remembered_like_any_other(engine, settings, local, ollama):
    settings.ai_fallback_to_local = True
    ollama.script = [say("answer")]
    orc(engine, cloud_failing(APIConnectionError("down"))).run("hello", 1, "phone")
    rows = orc(engine).history(5, 1)
    assert rows and rows[0]["instruction"] == "hello" and rows[0]["ok"]


# ------------------------------------------------------------ hostile local servers
def test_malformed_tool_calls_are_survived(engine, settings, local, ollama):
    settings.ai_provider = "local"
    ollama.script = [{"message": {"content": "", "tool_calls": [
        {"function": {"name": "status", "arguments": "{not json"}},
        {"function": {"name": 5, "arguments": {}}}, "junk", {"function": "x"},
        {"function": {"name": "system_info", "arguments": "{}"}}]}}, say("end")]
    r = orc(engine).run("x", 1, "phone")
    assert [s["tool"] for s in r.steps] == ["status", "system_info"] and r.ok


def test_at_most_four_tool_calls_per_answer(engine, settings, local, ollama):
    settings.ai_provider = "local"
    ollama.script = [say("", [("status", {})] * 9), say("end")]
    assert len(orc(engine).run("x", 1, "phone").steps) == 4


@pytest.mark.parametrize("raw", [(200, b"not json", {}), (200, b"{}", {}), (200, b'{"message": 5}', {}),
                                 (500, b"boom", {}), (200, b"x" * 1_100_000, {})])
def test_unreadable_or_oversized_answers_fail_safely(engine, settings, local, ollama, raw):
    settings.ai_provider = "local"
    ollama.raw = raw
    r = orc(engine).run("x", 1, "phone")
    assert not r.ok and r.steps == []


def test_a_redirect_is_never_followed(engine, settings, local, ollama):
    settings.ai_provider = "local"
    ollama.raw = (302, b"", {"Location": "http://example.com/steal"})
    r = orc(engine).run("x", 1, "phone")
    assert not r.ok


def test_the_local_model_cannot_change_the_tool_list_it_is_offered():
    class Rec:
        def __init__(self):
            self.sent = None

        def __call__(self, req, timeout=0):
            self.sent = json.loads(req.data)
            raise OSError("stop")

    rec = Rec()
    client = LocalClient("http://127.0.0.1:11434", "m", opener=rec)
    from agent.ai import build_tools as all_tools
    with pytest.raises(LocalAIError):
        client.create(model="m", max_tokens=10, system="s", messages=[{"role": "user", "content": "x"}],
                      tools=all_tools(gui_active=True))      # even a full list is cut down
    assert {t["function"]["name"] for t in rec.sent["tools"]} == set(LOCAL_TOOLS)


def test_message_conversion_round_trip():
    msgs = [{"role": "user", "content": "hi"},
            {"role": "assistant", "content": [__import__("types").SimpleNamespace(type="text", text="thinking"),
                                              __import__("types").SimpleNamespace(type="tool_use", id="1", name="status", input={})]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "1", "content": "result"}]}]
    out = to_ollama_messages("SYS", msgs)
    assert [m["role"] for m in out] == ["system", "user", "assistant", "tool"]
    assert out[2]["tool_calls"][0]["function"]["name"] == "status" and out[3]["content"] == "result"


def test_emergency_stop_and_step_cap_apply_to_the_local_model_too(engine, settings, local, ollama):
    settings.ai_provider = "local"
    settings.ai_max_steps = 2
    ollama.script = [say("", [("status", {})])] * 5
    r = orc(engine).run("loop", 1, "phone")
    assert "Step limit reached (2)" in r.stopped_reason and len(ollama.requests) == 2
    engine.ctx.stop_event.set()
    from agent.ai import AIUnavailable
    with pytest.raises(AIUnavailable):
        orc(engine).begin("x", 1, "phone")


# ------------------------------------------------------------ doctor / dry run
def test_doctor_reports_the_local_ai_setup(settings):
    def lines():
        return "\n".join(c.line() for c in run_checks(settings, env={}, startup_probe=lambda: None))

    assert "local AI fallback is off" in lines()
    settings.ai_fallback_to_local = True
    assert "local AI config problem" in lines()
    settings.ai_local_endpoint, settings.ai_local_model = "http://127.0.0.1:11434", "m"
    assert "local AI is configured" in lines()
    settings.ai_local_endpoint = "http://example.com:11434"
    assert "local AI config problem" in lines()


def test_dry_run_never_builds_a_local_client(settings, monkeypatch):
    import agent.ai as ai

    def boom(*a, **k):
        raise AssertionError("dry run must not build a client")

    monkeypatch.setattr(ai, "LocalClient", boom)
    monkeypatch.setattr(ai, "make_client", boom)
    assert "SYSTEM PROMPT" in dry_run_text(settings, "x")
