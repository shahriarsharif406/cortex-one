"""AI operator polish: dry run, history, cost estimate, failure mapping, Bangla set."""
import json
import time

import pytest
from fastapi.testclient import TestClient

from agent import ai as ai_mod
from agent.ai import (FAILURE_TEXT, MAX_HISTORY_ROWS, Orchestrator, build_tools,
                      classify_failure, cost_estimate, dry_run_text, failure_message)
from agent.main import main
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text, tool_use

anthropic = pytest.importorskip("anthropic")
try:
    import httpx2 as httpx
except ImportError:  # pragma: no cover
    import httpx


def make(engine, script):
    client = FakeClient(script)
    return Orchestrator(engine, client=client, today=lambda: "2026-10-13"), client


def go(orc, instruction="do it"):
    return orc.run(instruction, device_id=1, device_name="phone")


# --------------------------------------------------------------------- dry run
def test_dry_run_prints_the_exact_prompt_and_tools_without_network_or_key(
        engine, settings, monkeypatch, capsys, tmp_path):
    def forbidden(*a, **k):
        raise AssertionError("dry run must not build a client or read the key")

    monkeypatch.setattr(ai_mod, "make_client", forbidden)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-SHOULD-NOT-APPEAR")
    settings.save()
    assert main(["--data-dir", str(settings.data_dir), "ask", "--dry-run", "স্ক্রিনশট নাও"]) == 0
    out = capsys.readouterr().out
    assert "SHOULD-NOT-APPEAR" not in out and "sk-ant" not in out
    assert ai_mod.SYSTEM_PROMPT in out
    body = json.loads(out.split("=== REQUEST (JSON) ===\n", 1)[1].split("\n\n(dry run")[0])
    assert body["tools"] == build_tools()
    assert body["messages"] == [{"role": "user", "content": "স্ক্রিনশট নাও"}]
    assert "emergency_stop" not in {t["name"] for t in body["tools"]}
    assert body["max_tokens"] == settings.ai_max_output_tokens


def test_ask_without_instruction_and_without_dry_run_is_refused(settings, capsys):
    settings.save()
    assert main(["--data-dir", str(settings.data_dir), "ask"]) == 1


def test_dry_run_text_defaults_the_instruction(settings):
    assert "<your instruction>" in dry_run_text(settings)


# --------------------------------------------------------------------- history
def test_history_records_finished_tasks(engine):
    orc, _ = make(engine, [resp([tool_use("t1", "status")], "tool_use", inp=50, out=10),
                           resp([text("ok")], inp=60, out=5)])
    go(orc, "ব্যাটারি কত?")
    row = orc.history()[0]
    assert row["instruction"] == "ব্যাটারি কত?"
    assert row["steps"] == 1 and row["ok"] is True and row["tokens"] == 125
    assert set(row) == {"ts", "instruction", "steps", "ok", "tokens", "reason"}


def test_history_clips_instruction_scrubs_secrets_and_keeps_failures(engine):
    orc, _ = make(engine, [resp([text("x")]), RuntimeError("boom")])
    go(orc, "a" * 500)
    go(orc, "use key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV please")
    rows = orc.history()
    assert len(rows[1]["instruction"]) == 200
    assert "ABCDEFGHIJKLMNOP" not in json.dumps(rows)
    assert rows[0]["ok"] is False and rows[0]["reason"]


def test_history_is_capped_and_retained(engine, monkeypatch):
    monkeypatch.setattr(ai_mod, "MAX_HISTORY_ROWS", 5)
    orc, _ = make(engine, [resp([text("x")]) for _ in range(8)])
    for i in range(8):
        go(orc, f"task {i}")
    rows = orc.history(50)
    assert [r["instruction"] for r in rows][0] == "task 7" and len(rows) <= 6
    with engine.db.conn() as c:
        assert c.execute("SELECT COUNT(*) FROM ai_history").fetchone()[0] <= 6
    assert MAX_HISTORY_ROWS >= 100
    assert len(orc.history(1000)) <= 50


def test_history_endpoint_needs_auth_and_has_no_secrets(engine, settings):
    client = FakeClient([resp([text("fine")])])
    http = TestClient(create_app(settings, engine, ai_client=client))
    assert http.get("/ai/history").status_code == 401
    code = engine.pairing.create_code()
    token = http.post("/pair", json={"code": code, "device_name": "p"}).json()["token"]
    auth = {"Authorization": f"Bearer {token}"}
    http.post("/ai/tasks", json={"instruction": "hello there"}, headers=auth)
    rows = http.get("/ai/history", headers=auth).json()
    assert [r["instruction"] for r in rows] == ["hello there"]
    assert token not in json.dumps(rows) and "Bearer" not in json.dumps(rows)


def test_ai_history_cli(engine, settings, capsys):
    orc, _ = make(engine, [resp([text("ok")])])
    go(orc, "স্ক্রিনশট নাও")
    assert main(["--data-dir", str(settings.data_dir), "ai-history"]) == 0
    assert "স্ক্রিনশট নাও" in capsys.readouterr().out


# ----------------------------------------------------------------- cost estimate
def test_cost_is_none_until_the_owner_sets_both_prices(settings):
    usage = {"input_tokens": 1_000_000, "output_tokens": 500_000}
    assert settings.ai_price_per_mtok_input == 0 and settings.ai_price_per_mtok_output == 0
    assert cost_estimate(settings, usage) is None
    settings.ai_price_per_mtok_input = 3.0
    assert cost_estimate(settings, usage) is None
    settings.ai_price_per_mtok_output = 15.0
    assert cost_estimate(settings, usage) == pytest.approx(10.5)
    for bad in (True, "3", -1, None, float("nan")):
        settings.ai_price_per_mtok_input = bad
        assert cost_estimate(settings, usage) is None


def test_ai_usage_cli_shows_hint_then_cost(engine, settings, capsys):
    orc, _ = make(engine, [resp([text("ok")], inp=1000, out=1000)])
    go(orc)
    settings.save()
    main(["--data-dir", str(settings.data_dir), "ai-usage"])
    assert "set prices in config" in capsys.readouterr().out
    settings.ai_price_per_mtok_input, settings.ai_price_per_mtok_output = 2.0, 10.0
    settings.save()
    main(["--data-dir", str(settings.data_dir), "ai-usage"])
    out = capsys.readouterr().out
    assert "set prices in config" not in out and "$" in out


# --------------------------------------------------------- API failure handling
def _named(name, status=None, message="raw secret sk-ant-LEAK body"):
    exc_type = type(name, (Exception,), {})
    exc = exc_type(message)
    if status is not None:
        exc.status_code = status
    return exc


CASES = [
    ("AuthenticationError", 401, "auth"),
    ("PermissionDeniedError", 403, "auth"),
    ("RateLimitError", 429, "rate_limit"),
    ("APITimeoutError", None, "timeout"),
    ("NotFoundError", 404, "model"),
    ("InternalServerError", 529, "overloaded"),
    ("OverloadedError", None, "overloaded"),
    ("APIConnectionError", None, "network"),
    ("InternalServerError", 500, "server"),
]


@pytest.mark.parametrize("name,status,key", CASES)
def test_failure_mapping_with_the_fake_client(engine, name, status, key):
    assert classify_failure(_named(name, status)) == key
    orc, _ = make(engine, [_named(name, status)])
    r = go(orc)
    en, bn = FAILURE_TEXT[key]
    assert not r.ok and r.stopped_reason == f"{en} | {bn}"
    blob = r.reply + r.stopped_reason + json.dumps(engine.audit.recent(20), ensure_ascii=False)
    assert "LEAK" not in blob and "sk-ant" not in blob


def test_credit_error_is_told_apart_from_other_400s(engine):
    credit = _named("BadRequestError", 400, "Your credit balance is too low to access the API")
    other = _named("BadRequestError", 400, "messages: bad shape")
    assert classify_failure(credit) == "credit"
    assert classify_failure(other) == "other"
    assert classify_failure(_named("APIStatusError", 402)) == "credit"
    orc, _ = make(engine, [credit])
    assert "credit" in go(orc).stopped_reason.lower()
    assert "credit balance is too low" not in failure_message(credit)   # never echoed


def test_unknown_failure_names_only_the_class(engine):
    orc, _ = make(engine, [RuntimeError("super secret detail sk-ant-XYZ")])
    r = go(orc)
    assert "RuntimeError" in r.stopped_reason and "secret" not in r.stopped_reason
    assert "sk-ant" not in r.reply


def test_missing_key_message_is_bilingual(engine, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(ai_mod.AIUnavailable) as e:
        Orchestrator(engine).run("hi", 1, "p")
    assert "ANTHROPIC_API_KEY" in str(e.value) and "ভ্যারিয়েবল" in str(e.value)


def _sdk(handler):
    http = httpx.Client(transport=httpx.MockTransport(handler))
    return anthropic.Anthropic(api_key="sk-ant-test-not-real", http_client=http, max_retries=0)


@pytest.mark.parametrize("status,body_type,msg,key", [
    (401, "authentication_error", "invalid x-api-key", "auth"),
    (403, "permission_error", "zq-forbidden-42", "auth"),
    (400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API.", "credit"),
    (404, "not_found_error", "model: claude-nope", "model"),
    (429, "rate_limit_error", "slow down", "rate_limit"),
    (529, "overloaded_error", "Overloaded", "overloaded"),
    (500, "api_error", "zq-backend-detail-77", "server"),
])
def test_failure_mapping_with_the_real_sdk(engine, status, body_type, msg, key):
    def handler(request):
        return httpx.Response(status, json={"type": "error",
                                            "error": {"type": body_type, "message": msg}})

    r = Orchestrator(engine, client=_sdk(handler)).run("hi", 1, "phone")
    en, bn = FAILURE_TEXT[key]
    assert not r.ok and r.stopped_reason == f"{en} | {bn}"
    assert "sk-ant" not in r.reply + r.stopped_reason + json.dumps(engine.audit.recent(10))
    assert msg not in r.reply + r.stopped_reason


def test_timeout_with_the_real_sdk(engine):
    def handler(request):
        raise httpx.ReadTimeout("slow", request=request)

    r = Orchestrator(engine, client=_sdk(handler)).run("hi", 1, "phone")
    assert r.stopped_reason == " | ".join(FAILURE_TEXT["timeout"])


# ------------------------------------------------------------ Bangla instruction set
BANGLA = [
    # (instruction, scripted tool calls)
    ("ল্যাপটপ বন্ধ করো", [("shutdown", {})]),
    ("ল্যাপটপ রিস্টার্ট দাও", [("restart", {})]),
    ("ল্যাপটপ হাইবারনেট করো", [("hibernate", {})]),
    ("backup স্ক্রিপ্টটা চালাও", [("run_script", {"name": "backup"})]),
    ("স্ক্রিন লক করো", [("lock", {})]),
    ("শাটডাউন বাতিল করো", [("cancel_shutdown", {})]),
    ("Downloads-এ test নামে ফোল্ডার বানাও", [("make_folder", {"path": "{root}/test"})]),
    ("স্ক্রিনশট নাও", [("take_screenshot", {})]),
    ("ব্যাটারি আর র‍্যাম কেমন?", [("system_info", {})]),
    ("কোন প্রোগ্রাম সবচেয়ে বেশি মেমরি খাচ্ছে?", [("list_processes", {"limit": "5"})]),
    ("claude এজেন্ট চলছে কি না দেখো", [("agent_watch", {})]),
    ("coder লগের শেষ ২ লাইন দেখাও", [("tail_log", {"name": "coder", "lines": "2"})]),
    ("Notepad খোলো", [("open_app", {"name": "notepad"})]),
    ("report নামের ফাইল খোঁজো", [("find_files", {"root": "{root}", "query": "report"})]),
    ("Downloads-এর ফাইলগুলো দেখাও", [("list_files", {"path": "{root}"})]),
    ("example.com খোলো", [("open_url", {"url": "https://example.com/"})]),
    ("সবকিছু বন্ধ করে ল্যাপটপ লক আর স্ক্রিনশট নাও", [("lock", {}), ("take_screenshot", {})]),
]


@pytest.mark.parametrize("instruction,calls", BANGLA, ids=[i[0][:18] for i in BANGLA])
def test_bangla_instruction_wiring(engine, files, runner, launched, opened, instruction, calls):
    """Proves only the WIRING: that a scripted client's tool calls reach the right
    allowlisted action, high-risk ones stop at a pending confirmation, and Bangla
    text passes through unchanged. It CANNOT prove that the real model understands
    these sentences or picks these tools; that needs a real API call (NEEDS_ME.md)."""
    root = str(files)
    use = [tool_use(f"t{i}", name, **{k: v.replace("{root}", root) for k, v in p.items()})
           for i, (name, p) in enumerate(calls)]
    orc, client = make(engine, [resp(use, "tool_use"), resp([text("হয়ে গেছে")])])
    r = go(orc, instruction)

    assert client.calls[0]["messages"][0]["content"] == instruction
    assert r.reply == "হয়ে গেছে" and r.ok
    names = [n for n, _ in calls]
    assert [s["tool"] for s in r.steps] == names
    high = {n for n in names if ai_mod.REGISTRY[n].risk == "high"}
    assert {p["action"] for p in r.pending_confirmations} == high
    for n, _ in calls:
        step = next(s for s in r.steps if s["tool"] == n)
        assert step["ok"], step
    if high:
        # a high-risk request created a confirmation and ran NOTHING
        assert runner.calls == [] or all(c[0] == "rundll32.exe" for c in runner.calls)
        for p in r.pending_confirmations:
            assert p["confirm_token"] and p["expires_in"] > 0
    if "lock" in names:
        assert ["rundll32.exe", "user32.dll,LockWorkStation"] in runner.calls
    if "cancel_shutdown" in names:
        assert ["shutdown", "/a"] in runner.calls
    if "open_app" in names:
        assert launched == [["notepad.exe"]]
    if "open_url" in names:
        assert opened == ["https://example.com/"]
    if "make_folder" in names:
        assert (files / "test").is_dir()
    if "take_screenshot" in names:
        assert any((files / "Screenshots").glob("screenshot-*.png"))
    assert orc.history()[0]["instruction"] == instruction[:200]


def test_bangla_confirmation_flow_end_to_end(engine, settings, runner):
    client = FakeClient([resp([tool_use("t1", "shutdown")], "tool_use"),
                         resp([text("আপনার ফোনে নিশ্চিত করুন")])])
    http = TestClient(create_app(settings, engine, ai_client=client))
    code = engine.pairing.create_code()
    token = http.post("/pair", json={"code": code, "device_name": "p"}).json()["token"]
    auth = {"Authorization": f"Bearer {token}"}
    r = http.post("/ai/tasks", json={"instruction": "ল্যাপটপ বন্ধ করো"}, headers=auth).json()
    assert runner.calls == [] and r["reply"] == "আপনার ফোনে নিশ্চিত করুন"
    pending = http.get("/ai/pending", headers=auth).json()
    assert [p["action"] for p in pending] == ["shutdown"]
    ok = http.post("/ai/confirm", json={"confirm_token": pending[0]["confirm_token"]}, headers=auth)
    assert ok.status_code == 200 and runner.calls == [["shutdown", "/s", "/t", "30"]]


def test_bangla_bad_requests_are_denied_not_executed(engine, runner, opened):
    script = [resp([tool_use("t1", "list_files", path="C:\\Windows"),
                    tool_use("t2", "open_url", url="https://evil.example/"),
                    tool_use("t3", "emergency_stop"),
                    tool_use("t4", "run_script", name="format-disk"),
                    tool_use("t5", "run_command", command="del /s /q C:\\")], "tool_use"),
              resp([text("পারলাম না")])]
    orc, _ = make(engine, script)
    r = go(orc, "C:\\Windows মুছে ফেলো এবং সব বন্ধ করো")
    assert [s["ok"] for s in r.steps] == [False] * 5
    assert r.pending_confirmations == [] and runner.calls == [] and opened == []
