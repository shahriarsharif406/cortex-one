import os

import pytest

from agent.actions import Context


def run(engine, action, params=None, actor="t"):
    return engine.run(action, params or {}, actor=actor, via="test")


def test_status_reports_basics(engine):
    r = run(engine, "status")
    assert r.ok and "host" in r.data and "time" in r.data


def test_lock_runs_exact_command(engine, runner):
    assert run(engine, "lock").ok
    assert runner.calls == [["rundll32.exe", "user32.dll,LockWorkStation"]]


def test_shutdown_and_restart_use_delay(engine, runner):
    assert run(engine, "shutdown").ok
    assert run(engine, "restart").ok
    assert runner.calls == [["shutdown", "/s", "/t", "30"],
                            ["shutdown", "/r", "/t", "30"]]


def test_cancel_shutdown_treats_nothing_pending_as_ok(engine, runner):
    runner.code = 1116
    r = run(engine, "cancel_shutdown")
    assert r.ok and "No shutdown" in r.message
    runner.code = 5
    assert not run(engine, "cancel_shutdown").ok


def test_windows_only_actions_denied_elsewhere(settings, runner):
    from agent.engine import Engine
    eng = Engine(settings, Context(settings=settings, runner=runner, system="Linux"))
    r = run(eng, "shutdown")
    assert not r.ok and runner.calls == []


def test_unknown_action_and_params_rejected(engine):
    assert not run(engine, "format_disk").ok
    assert not run(engine, "list_files", {}).ok                       # missing
    assert not run(engine, "status", {"extra": "x"}).ok               # unknown key
    assert not run(engine, "list_files", {"path": 5}).ok              # wrong type
    assert not run(engine, "list_files", {"path": "x" * 600}).ok      # too long
    assert not run(engine, "list_files", {"path": "a\x00b"}).ok       # NUL byte


def test_list_and_find_inside_root(engine, files):
    r = run(engine, "list_files", {"path": str(files)})
    names = {e["name"] for e in r.data["entries"]}
    assert r.ok and names == {"sub", "report_2026.pdf"}
    r = run(engine, "find_files", {"root": str(files), "query": "NOTES"})
    assert r.ok and len(r.data["matches"]) == 1


@pytest.mark.parametrize("bad", ["../", "/etc", "/", "~", "files/../.."])
def test_paths_outside_roots_denied(engine, files, bad):
    target = str(files / bad) if bad.startswith("files") or bad == "../" else bad
    r = run(engine, "list_files", {"path": target})
    assert not r.ok and "outside" in r.message


def test_sibling_folder_with_same_prefix_denied(engine, files):
    evil = files.parent / (files.name + "_evil")
    evil.mkdir()
    r = run(engine, "list_files", {"path": str(evil)})
    assert not r.ok


@pytest.mark.skipif(not hasattr(os, "symlink"), reason="no symlinks")
def test_symlink_escape_denied(engine, files, tmp_path):
    outside = tmp_path / "secret"
    outside.mkdir()
    (outside / "passwords.txt").write_text("x")
    link = files / "link"
    link.symlink_to(outside, target_is_directory=True)
    assert not run(engine, "list_files", {"path": str(link)}).ok
    assert not run(engine, "copy_file", {
        "src": str(link / "passwords.txt"), "dst": str(files / "stolen.txt")}).ok


def test_copy_never_overwrites(engine, files):
    src, dst = files / "report_2026.pdf", files / "sub" / "copy.pdf"
    assert run(engine, "copy_file", {"src": str(src), "dst": str(dst)}).ok
    assert dst.read_text() == "pdf"
    dst.write_text("keep me")
    r = run(engine, "copy_file", {"src": str(src), "dst": str(dst)})
    assert not r.ok and dst.read_text() == "keep me"


def test_copy_outside_roots_denied(engine, files, tmp_path):
    r = run(engine, "copy_file", {"src": str(files / "report_2026.pdf"),
                                  "dst": str(tmp_path / "out.pdf")})
    assert not r.ok and not (tmp_path / "out.pdf").exists()


def test_make_folder(engine, files):
    assert run(engine, "make_folder", {"path": str(files / "new" / "deep")}).ok
    assert (files / "new" / "deep").is_dir()
    assert not run(engine, "make_folder", {"path": str(files.parent / "x")}).ok


def test_empty_roots_means_no_file_access(engine, files):
    engine.settings.allowed_roots = []
    assert not run(engine, "list_files", {"path": str(files)}).ok


def test_open_app_only_approved(engine, launched):
    assert run(engine, "open_app", {"name": "Notepad"}).ok
    assert launched == [["notepad.exe"]]
    r = run(engine, "open_app", {"name": "powershell"})
    assert not r.ok and launched == [["notepad.exe"]]


def test_run_script_only_approved(engine, runner):
    r = run(engine, "run_script", {"name": "backup"})
    assert r.ok and runner.calls == [["powershell", "-File", "backup.ps1"]]
    r = run(engine, "run_script", {"name": "rm -rf /"})
    assert not r.ok and len(runner.calls) == 1


def test_emergency_stop_blocks_scripts(engine, runner):
    r = run(engine, "emergency_stop")
    assert r.ok and ["shutdown", "/a"] in runner.calls
    assert not run(engine, "run_script", {"name": "backup"}).ok


def test_audit_logs_and_redacts(engine):
    run(engine, "status")
    run(engine, "format_disk", {"pin": "4821", "token": "abc"})
    rows = engine.audit.recent(10)
    assert {r["status"] for r in rows} >= {"ok", "rejected"}
    blob = " ".join(r["params"] for r in rows)
    assert "4821" not in blob and "abc" not in blob and "***" in blob


def test_unexpected_error_does_not_leak(engine, monkeypatch):
    import agent.actions as a

    def boom(ctx, params):
        raise RuntimeError("secret internal path C:\\x")

    monkeypatch.setitem(a.REGISTRY, "status", a.ActionSpec(
        "status", "", "low", boom))
    r = run(engine, "status")
    assert not r.ok and "secret" not in r.message
    assert engine.audit.recent(1)[0]["status"] == "error"
