"""Runs the orchestrator against the REAL anthropic SDK, with only the HTTP
layer faked. Proves our code works with the SDK's actual response objects and
sends well-formed requests. (It does not prove the live API accepts them:
that needs a real key, see NEEDS_ME.md.)"""
import json

import pytest

anthropic = pytest.importorskip("anthropic")
# Newer SDKs are built on httpx2, older ones on httpx; use whichever it expects.
try:
    import httpx2 as httpx
except ImportError:  # pragma: no cover
    import httpx

from agent.ai import Orchestrator  # noqa: E402


def message(content, stop_reason, inp=10, out=5):
    return {"id": "msg_test", "type": "message", "role": "assistant",
            "model": "claude-sonnet-5-5", "content": content,
            "stop_reason": stop_reason, "stop_sequence": None,
            "usage": {"input_tokens": inp, "output_tokens": out}}


def sdk_client(responses, seen):
    def handler(request: httpx.Request) -> httpx.Response:
        seen.append({"path": request.url.path, "key": request.headers.get("x-api-key"),
                     "body": json.loads(request.content)})
        return httpx.Response(200, json=responses.pop(0))

    http = httpx.Client(transport=httpx.MockTransport(handler))
    return anthropic.Anthropic(api_key="sk-ant-test-not-real", http_client=http,
                               max_retries=0)


def test_tool_loop_with_real_sdk_objects(engine, files):
    seen = []
    client = sdk_client([
        message([{"type": "text", "text": "Checking."},
                 {"type": "tool_use", "id": "toolu_01", "name": "list_files",
                  "input": {"path": str(files)}}], "tool_use"),
        message([{"type": "text", "text": "দুটি আইটেম পাওয়া গেছে।"}], "end_turn"),
    ], seen)
    r = Orchestrator(engine, client=client, today=lambda: "2026-10-13").run(
        "ফাইল দেখাও", 1, "phone")
    assert r.ok and r.reply == "দুটি আইটেম পাওয়া গেছে।" and r.tokens_used == 30

    first, second = seen
    assert first["path"] == "/v1/messages" and first["key"] == "sk-ant-test-not-real"
    body = first["body"]
    assert body["model"] == "claude-sonnet-5-5" and body["max_tokens"] == 1024
    assert {t["name"] for t in body["tools"]} >= {"status", "list_files", "shutdown"}
    assert "emergency_stop" not in {t["name"] for t in body["tools"]}
    assert body["messages"] == [{"role": "user", "content": "ফাইল দেখাও"}]

    # second request: assistant tool_use echoed back, then our tool_result
    msgs = second["body"]["messages"]
    assert [m["role"] for m in msgs] == ["user", "assistant", "user"]
    assert msgs[1]["content"][-1]["type"] == "tool_use"
    assert msgs[1]["content"][-1]["id"] == "toolu_01"
    result = msgs[2]["content"][0]
    assert result["type"] == "tool_result" and result["tool_use_id"] == "toolu_01"
    assert "report_2026.pdf" in result["content"]


def test_high_risk_via_real_sdk_is_still_only_pending(engine, runner):
    seen = []
    client = sdk_client([
        message([{"type": "tool_use", "id": "toolu_02", "name": "shutdown", "input": {}}],
                "tool_use"),
        message([{"type": "text", "text": "Please confirm on your phone."}], "end_turn"),
    ], seen)
    r = Orchestrator(engine, client=client).run("shut down", 1, "phone")
    assert runner.calls == [] and len(r.pending_confirmations) == 1
    assert "Not executed" in seen[1]["body"]["messages"][-1]["content"][0]["content"]


def test_http_error_from_the_api_is_contained(engine):
    def handler(request):
        return httpx.Response(401, json={"type": "error", "error": {
            "type": "authentication_error", "message": "invalid x-api-key"}})

    http = httpx.Client(transport=httpx.MockTransport(handler))
    client = anthropic.Anthropic(api_key="sk-ant-test-not-real", http_client=http,
                                 max_retries=0)
    r = Orchestrator(engine, client=client).run("hi", 1, "phone")
    assert not r.ok and "ANTHROPIC_API_KEY" in r.stopped_reason
    assert "sk-ant" not in r.reply + r.stopped_reason + str(engine.audit.recent(10))


def test_pictures_are_serialised_as_image_blocks_by_the_real_sdk(engine):
    import base64
    import io

    from PIL import Image

    from agent.images import validate_images

    buf = io.BytesIO()
    Image.new("RGB", (32, 32), (1, 2, 3)).save(buf, "PNG")
    raw = base64.b64encode(buf.getvalue()).decode()
    seen = []
    client = sdk_client([message([{"type": "text", "text": "A small square."}], "end_turn")], seen)
    r = Orchestrator(engine, client=client, today=lambda: "2026-10-17").run(
        "what is it?", 1, "phone", validate_images([{"media_type": "image/png", "data": raw}]))
    assert r.ok
    content = seen[0]["body"]["messages"][0]["content"]
    assert content[0] == {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                                      "data": raw}}
    assert content[1] == {"type": "text", "text": "what is it?"}
