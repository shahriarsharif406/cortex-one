"""Findings from the independent review of the 1.0.0-rc1 changes."""
import subprocess
import sys
import threading
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from agent.logging_setup import scrub
from agent.server import create_app

from .fake_anthropic import FakeClient, resp, text

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import precommit_check as pc  # noqa: E402

TOKEN = "q8Zr2LmN7xKp4TvB9wYc1HsD6fGj3AeU"


# 1. a file must not be able to switch off its own scan
def test_forged_diff_header_line_cannot_hide_a_secret(tmp_path, monkeypatch):
    run = lambda *a: subprocess.run(a, cwd=tmp_path, capture_output=True, text=True)  # noqa: E731
    run("git", "init", "-q")
    (tmp_path / "a.py").write_text(f"++ x\nTOKEN_VALUE = \"{TOKEN}\"\n")
    (tmp_path / "we ird\u00e9 \u09ac.py").write_text(f'TOKEN_VALUE = "{TOKEN}"\n')
    run("git", "add", "-A")
    monkeypatch.chdir(tmp_path)
    found = pc.staged_findings()
    assert any(x.startswith("a.py:2") for x in found), found
    assert any("ird\u00e9 \u09ac.py:1" in x for x in found), found


# 9. a huge single line must not stall the scan
def test_very_long_line_is_skipped_quickly():
    import time

    t = time.time()
    assert pc.scan_line("a.js", "x" * 2_000_000) is None
    assert time.time() - t < 1


# 2. more phrasings of PIN-in-free-text are masked
@pytest.mark.parametrize("src", [
    "my pin number is 1234", "pin 4821", "password hunter2", "PIN - 9999", "the code is: 5555",
    "পিন হলো 4821", "passcode=8821", "my password is\nhunter2",
])
def test_pin_phrasings_are_scrubbed(src):
    out = scrub(src)
    for secret in ("1234", "4821", "hunter2", "9999", "5555", "8821"):
        assert secret not in out, (src, out)


def test_scrub_leaves_ordinary_text_alone():
    assert scrub("open the pin board app") == "open the pin board app"
    assert scrub("ল্যাপটপ বন্ধ করো") == "ল্যাপটপ বন্ধ করো"


# 4. scrub first, then clip
def test_secret_straddling_the_clip_boundary_is_not_kept(engine):
    from agent.ai import Orchestrator

    orc = Orchestrator(engine, client=FakeClient([resp([text("x")])]))
    orc.run("a" * 190 + " my password is hunter2xyz", 1, "p")
    row = orc.history()[0]["instruction"]
    assert "hunter" not in row
    assert "hunter" not in repr(engine.audit.recent(5))


# 3. AI history is private to the device
def test_ai_history_is_per_device(engine, settings):
    client = FakeClient([resp([text("a")]), resp([text("b")])])
    http = TestClient(create_app(settings, engine, ai_client=client))

    def pair(name):
        code = engine.pairing.create_code()
        return {"Authorization": "Bearer " + http.post(
            "/pair", json={"code": code, "device_name": name}).json()["token"]}

    phone, tablet = pair("phone"), pair("tablet")
    http.post("/ai/tasks", json={"instruction": "phone secret task"}, headers=phone)
    http.post("/ai/tasks", json={"instruction": "tablet task"}, headers=tablet)
    assert [r["instruction"] for r in http.get("/ai/history", headers=phone).json()] == ["phone secret task"]
    assert [r["instruction"] for r in http.get("/ai/history", headers=tablet).json()] == ["tablet task"]


def test_old_ai_history_table_gets_the_device_column(tmp_path):
    import sqlite3

    from agent.db import Database

    path = tmp_path / "old.db"
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE ai_history (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, "
              "instruction TEXT NOT NULL, steps INTEGER NOT NULL, ok INTEGER NOT NULL, "
              "tokens INTEGER NOT NULL, reason TEXT NOT NULL DEFAULT '')")
    c.commit(); c.close()
    db = Database(path)
    with db.conn() as c:
        assert "device_id" in [r[1] for r in c.execute("PRAGMA table_info(ai_history)")]


# 5. GET /watch must not wait for a tick that is stuck on slow I/O
def test_snapshot_does_not_wait_for_a_stuck_tick(engine):
    from agent.watch import RuleWatcher

    engine.settings.watch_rules = [{"name": "x", "kind": "log_stalled", "target": "coder", "minutes": 5}]
    release = threading.Event()

    def hung_stat(path):
        release.wait(5)
        return None

    rw = RuleWatcher(engine, stat=hung_stat)
    t = threading.Thread(target=rw.tick, daemon=True)
    t.start()
    done = []
    s = threading.Thread(target=lambda: done.append(rw.snapshot()), daemon=True)
    s.start()
    s.join(1.5)
    release.set()
    t.join(5)
    assert done, "snapshot blocked behind the running tick"
