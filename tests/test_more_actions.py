"""make_document and archive_file."""
import zipfile
from xml.dom import minidom

import pytest
from fastapi.testclient import TestClient

from agent import actions as A
from agent.actions import REGISTRY
from agent.ai import Orchestrator

from .fake_anthropic import FakeClient, resp, text, tool_use


def run(engine, action, params=None, via="test"):
    return engine.run(action, params or {}, actor="t", via=via)


@pytest.fixture
def rep(settings, files):
    settings.reports_dir = files / "Reports"
    return settings.reports_dir


@pytest.fixture
def arc(settings, files):
    settings.archive_dir = files / "Archive"
    return settings.archive_dir


# ----------------------------------------------------------- make_document
def parts(path):
    with zipfile.ZipFile(path) as z:
        out = {n: z.read(n).decode("utf-8") for n in z.namelist()}
    for n, body in out.items():
        minidom.parseString(body.encode("utf-8"))        # every part is well-formed XML
    return out


def test_docx_ok_bangla_and_escaping(engine, rep):
    r = run(engine, "make_document", {"kind": "docx", "name": "letter",
                                      "content": "# Title\nআমার চিঠি <b>&</b>\n\x1b[31mred"})
    assert r.ok
    p = parts(rep / "letter.docx")
    body = p["word/document.xml"]
    assert "আমার চিঠি &lt;b&gt;&amp;&lt;/b&gt;" in body and "Heading1" in body and "\x1b" not in body


def test_xlsx_values_only_never_formulas(engine, rep):
    r = run(engine, "make_document", {"kind": "xlsx", "name": "t",
                                      "content": "name,amount\nrent,1200\n=cmd|' /c calc'!A0,-5.5\n"})
    assert r.ok
    sheet = parts(rep / "t.xlsx")["xl/worksheets/sheet1.xml"]
    assert "<f>" not in sheet and "<v>1200</v>" in sheet and "<v>-5.5</v>" in sheet
    assert "inlineStr" in sheet and "=cmd" in sheet          # stored as text, not a formula


def test_xlsx_tab_split_and_limits(engine, rep, monkeypatch):
    assert run(engine, "make_document", {"kind": "xlsx", "name": "a", "content": "a,b\tc"}).ok
    assert "b" in parts(rep / "a.xlsx")["xl/worksheets/sheet1.xml"]
    monkeypatch.setattr(A, "MAX_DOC_ROWS", 3)
    assert not run(engine, "make_document", {"kind": "xlsx", "name": "b", "content": "1\n2\n3\n4"}).ok
    assert not (rep / "b.xlsx").exists()
    assert not run(engine, "make_document", {"kind": "xlsx", "name": "c",
                                             "content": ",".join("x" * 60)}).ok


@pytest.mark.parametrize("params", [
    {"kind": "pdf", "name": "a", "content": "x"}, {"kind": "exe", "name": "a", "content": "x"},
    {"kind": "docx", "name": "../a", "content": "x"}, {"kind": "docx", "name": "a", "content": "  "},
    {"kind": "docx", "name": "a"}, {"kind": "docx", "name": "NUL", "content": "x"},
    {"kind": "docx", "name": "a", "content": "x" * (A.MAX_LONG_PARAM + 1)}])
def test_make_document_bad_params(engine, rep, params):
    assert not run(engine, "make_document", params).ok
    assert not rep.exists() or not list(rep.iterdir())


def test_make_document_never_overwrites_and_needs_folder(engine, rep, settings, tmp_path):
    assert run(engine, "make_document", {"kind": "docx", "name": "d", "content": "one"}).ok
    before = (rep / "d.docx").read_bytes()
    assert not run(engine, "make_document", {"kind": "docx", "name": "d", "content": "two"}).ok
    assert (rep / "d.docx").read_bytes() == before
    settings.reports_dir = tmp_path / "elsewhere"
    assert not run(engine, "make_document", {"kind": "docx", "name": "e", "content": "x"}).ok


def test_make_document_scrubs_keys_and_audit_hides_content(engine, rep):
    secret = "sk-ant-api03-" + "C" * 40
    run(engine, "make_document", {"kind": "docx", "name": "s", "content": f"hello zebra {secret}"})
    assert "C" * 40 not in parts(rep / "s.docx")["word/document.xml"]
    assert "zebra" not in str(engine.audit.recent(20))


# ----------------------------------------------------------- archive_file
def test_archive_requires_confirmation_over_http_and_moves(engine, settings, files, arc):
    http = TestClient(__import__("agent.server", fromlist=["x"]).create_app(settings, engine))
    code = engine.pairing.create_code()
    tok = http.post("/pair", json={"code": code, "device_name": "p"}).json()["token"]
    h = {"Authorization": f"Bearer {tok}"}
    src = files / "old.txt"
    src.write_text("keep me")
    r = http.post("/actions/archive_file", json={"params": {"src": str(src)}}, headers=h).json()
    assert r["status"] == "confirmation_required" and src.exists()        # nothing moved yet
    r2 = http.post("/actions/archive_file", json={"params": {"src": str(src)},
                                                  "confirm_token": r["confirm_token"]}, headers=h)
    assert r2.status_code == 200 and not src.exists()
    moved = list(arc.iterdir())
    assert len(moved) == 1 and moved[0].name.endswith("_old.txt") and moved[0].read_text() == "keep me"


def test_archive_denials_before_confirmation(engine, settings, files, arc, tmp_path):
    http = TestClient(__import__("agent.server", fromlist=["x"]).create_app(settings, engine))
    tok = http.post("/pair", json={"code": engine.pairing.create_code(), "device_name": "p"}).json()["token"]
    h = {"Authorization": f"Bearer {tok}"}
    outside = tmp_path / "o.txt"
    outside.write_text("x")
    settings.screenshots_dir.mkdir(parents=True, exist_ok=True)
    shot = settings.screenshots_dir / "s.txt"
    shot.write_text("x")
    for src in (str(outside), str(files / "sub"), str(files / "nope.txt"), str(shot),
                str(files / ".." / "o.txt")):
        r = http.post("/actions/archive_file", json={"params": {"src": src}}, headers=h)
        assert "confirm_token" not in r.json(), src          # refused before the owner is asked
        assert outside.exists() and shot.exists()


def test_archive_direct_denials_and_no_overwrite(engine, settings, files, arc, tmp_path, monkeypatch):
    a = files / "a.txt"
    a.write_text("1")
    (arc).mkdir()
    monkeypatch.setattr(A.time, "strftime", lambda f: "20261023-000000")
    (arc / "20261023-000000_a.txt").write_text("existing")
    assert run(engine, "archive_file", {"src": str(a)}).ok
    assert (arc / "20261023-000000_a.txt").read_text() == "existing"           # not overwritten
    assert (arc / "20261023-000000-1_a.txt").read_text() == "1"
    assert not run(engine, "archive_file", {"src": str(arc / "20261023-000000_a.txt")}).ok  # already archived
    settings.archive_dir = tmp_path / "elsewhere"
    b = files / "b.txt"
    b.write_text("2")
    assert not run(engine, "archive_file", {"src": str(b)}).ok and b.exists()
    assert not run(engine, "archive_file", {}).ok


def test_archive_data_dir_protected(engine, settings, files, arc):
    settings.allowed_roots = [files, settings.data_dir]
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    f = settings.data_dir / "x.txt"
    f.write_text("x")
    assert not run(engine, "archive_file", {"src": str(f)}).ok and f.exists()


def test_archive_ai_can_only_request(engine, files, arc):
    f = files / "ai.txt"
    f.write_text("x")
    client = FakeClient([resp([tool_use("t1", "archive_file", src=str(f))], "tool_use"),
                         resp([text("done")])])
    r = Orchestrator(engine, client=client, today=lambda: "2026-10-23").run(
        "archive it", device_id=1, device_name="p")
    assert f.exists() and not arc.exists()
    assert [p["action"] for p in r.pending_confirmations] == ["archive_file"]
    assert not run(engine, "archive_file", {"src": str(f)}, via="ai").ok and f.exists()


def test_roles_and_risk():
    assert REGISTRY["archive_file"].risk == "high" and REGISTRY["make_document"].risk == "low"


def test_archive_name_appearing_midway_is_not_overwritten(engine, files, arc, monkeypatch):
    f = files / "race.txt"
    f.write_text("mine")
    real_link = A.os.link

    def racing_link(src, dst):
        open(dst, "w").write("someone else")        # the name got taken after we chose it
        raise FileExistsError()
    monkeypatch.setattr(A.os, "link", racing_link)
    r = run(engine, "archive_file", {"src": str(f)})
    assert not r.ok and f.read_text() == "mine"
    assert [p.read_text() for p in arc.iterdir()] == ["someone else"]
    monkeypatch.setattr(A.os, "link", real_link)
