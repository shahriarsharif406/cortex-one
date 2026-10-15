import struct
import time
import zlib
from types import SimpleNamespace as NS

import psutil
import pytest

from agent.actions import REGISTRY, check_url
from agent.screen import encode_png


def run(engine, action, params=None):
    return engine.run(action, params or {}, actor="t", via="test")


def fake_procs(monkeypatch, rows):
    """rows: (name, rss_bytes, create_time)"""
    def process_iter(attrs=None):
        for name, rss, created in rows:
            yield NS(info={"name": name, "memory_info": NS(rss=rss), "create_time": created})
    monkeypatch.setattr(psutil, "process_iter", process_iter)


# -------------------------------------------------------------- registry
def test_new_actions_are_registered_low_risk_and_take_no_free_form_input():
    for name in ("system_info", "list_processes", "take_screenshot", "open_url",
                 "tail_log", "agent_watch"):
        assert REGISTRY[name].risk == "low"
    # no parameter anywhere may look like a shell command or arbitrary path
    for spec in REGISTRY.values():
        for p in spec.params + spec.optional:
            assert p not in {"cmd", "command", "shell", "args", "exec"}
    assert REGISTRY["tail_log"].params == ("name",)        # a short name, never a path
    assert REGISTRY["take_screenshot"].params == ()        # file name is chosen by the agent


# ------------------------------------------------------------ system_info
def test_system_info_reports_machine_state(engine, monkeypatch):
    monkeypatch.setattr(psutil, "sensors_battery",
                        lambda: NS(percent=81.4, power_plugged=True))
    r = run(engine, "system_info")
    assert r.ok
    for key in ("cpu_percent", "ram_total_mb", "ram_used_percent", "uptime_minutes",
                "disk_free_gb", "disk_used_percent"):
        assert key in r.data
    assert r.data["battery_percent"] == 81 and r.data["plugged_in"] is True


def test_system_info_without_battery(engine, monkeypatch):
    monkeypatch.setattr(psutil, "sensors_battery", lambda: None)
    assert "battery_percent" not in run(engine, "system_info").data


def test_system_info_rejects_params(engine):
    assert not run(engine, "system_info", {"x": "1"}).ok


# ---------------------------------------------------------- list_processes
def test_list_processes_top_n_names_only(engine, monkeypatch):
    fake_procs(monkeypatch, [("chrome.exe", 300 << 20, 0), ("chrome.exe", 200 << 20, 0),
                             ("code.exe", 400 << 20, 0), ("tiny.exe", 1 << 20, 0)])
    r = run(engine, "list_processes", {"limit": "2"})
    assert r.ok
    assert [p["name"] for p in r.data["processes"]] == ["chrome.exe", "code.exe"]
    assert r.data["processes"][0] == {"name": "chrome.exe", "memory_mb": 500, "count": 2}
    assert all(set(p) == {"name", "memory_mb", "count"} for p in r.data["processes"])


def test_list_processes_defaults_and_bad_limits(engine, monkeypatch):
    fake_procs(monkeypatch, [(f"p{i}.exe", i << 20, 0) for i in range(40)])
    assert len(run(engine, "list_processes").data["processes"]) == 10
    for bad in ("0", "26", "-1", "abc", "1.5", "１２", " ", "10; shutdown"):
        assert not run(engine, "list_processes", {"limit": bad}).ok, bad
    assert not run(engine, "list_processes", {"limit": 5}).ok          # must be a string
    assert not run(engine, "list_processes", {"cmdline": "x"}).ok


def test_process_names_are_sanitised(engine, monkeypatch):
    fake_procs(monkeypatch, [("evil\x1b[31m\x00\u202e.exe", 5 << 20, 0)])
    name = run(engine, "list_processes").data["processes"][0]["name"]
    assert "\x1b" not in name and "\x00" not in name and "\u202e" not in name


# ------------------------------------------------------------- agent_watch
def test_agent_watch_lists_only_watched_programs(engine, monkeypatch):
    t = time.time() - 3600
    fake_procs(monkeypatch, [("claude.exe", 100 << 20, t), ("node.exe", 50 << 20, t),
                             ("node.exe", 25 << 20, t), ("secret-tool.exe", 1 << 20, t)])
    r = run(engine, "agent_watch")
    assert r.ok
    by_name = {p["program"]: p for p in r.data["programs"]}
    assert set(by_name) == {"claude", "node"}                  # nothing outside the allowlist
    assert len(by_name["node"]["instances"]) == 2 and by_name["claude"]["running"]
    assert by_name["claude"]["instances"][0]["memory_mb"] == 100
    assert by_name["claude"]["instances"][0]["started"]
    assert "secret-tool" not in str(r.data)


def test_agent_watch_reports_not_running_and_needs_config(engine, monkeypatch):
    fake_procs(monkeypatch, [("explorer.exe", 1 << 20, 0)])
    r = run(engine, "agent_watch")
    assert r.ok and not any(p["running"] for p in r.data["programs"])
    engine.settings.watched_programs = []
    assert not run(engine, "agent_watch").ok
    assert not run(engine, "agent_watch", {"name": "python"}).ok   # cannot pick its own targets


# --------------------------------------------------------- take_screenshot
def test_screenshot_saved_inside_allowed_folder(engine, settings):
    r = run(engine, "take_screenshot")
    assert r.ok and r.data["file"].startswith("screenshot-") and r.data["file"].endswith(".png")
    assert (settings.screenshots_dir / r.data["file"]).read_bytes().startswith(b"\x89PNG")
    assert "\\" not in r.data["file"] and "/" not in r.data["file"]   # a name, not a path


def test_two_screenshots_in_one_second_do_not_overwrite(engine, settings):
    names = {run(engine, "take_screenshot").data["file"] for _ in range(3)}
    assert len(names) == 3


def test_screenshot_folder_outside_roots_is_denied(engine, settings, tmp_path):
    settings.screenshots_dir = tmp_path / "not-allowed"
    r = run(engine, "take_screenshot")
    assert not r.ok and "outside" in r.message
    assert not (tmp_path / "not-allowed").exists()


def test_screenshot_rejects_params_and_non_windows(engine, settings):
    assert not run(engine, "take_screenshot", {"path": "C:\\x.png"}).ok
    engine.ctx.system = "Linux"
    assert not run(engine, "take_screenshot").ok


def test_screenshot_failure_is_a_clean_error(engine):
    def boom(path):
        raise OSError("locked")
    engine.ctx.screenshotter = boom
    r = run(engine, "take_screenshot")
    assert not r.ok and "Screenshot failed" in r.message


def test_screenshot_folder_cap(engine, settings, monkeypatch):
    import agent.actions as actions
    monkeypatch.setattr(actions, "MAX_SCREENSHOTS", 2)
    # Our own screenshots are auto-pruned (screenshot_keep), so they never fill the
    # folder. Files we did not name (and so never delete) still count toward the cap.
    settings.screenshots_dir.mkdir(parents=True)
    for i in range(2):
        (settings.screenshots_dir / f"screenshot-mine-{i}.png").write_bytes(b"x")
    r = run(engine, "take_screenshot")
    assert not r.ok and "full" in r.message
    assert len(list(settings.screenshots_dir.glob("screenshot-mine-*.png"))) == 2


def test_png_encoder_makes_a_valid_png():
    w, h = 3, 2
    bgra = bytes([10, 20, 30, 255] * (w * h))               # B, G, R, A
    png = encode_png(w, h, bgra)
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    ihdr = png[16:29]
    assert struct.unpack(">II", ihdr[:8]) == (w, h)
    idat_len = struct.unpack(">I", png[33:37])[0]
    raw = zlib.decompress(png[41:41 + idat_len])
    assert raw[:4] == bytes([0, 30, 20, 10])                # filter byte then RGB
    with pytest.raises(ValueError):
        encode_png(2, 2, b"short")


# ----------------------------------------------------------------- open_url
def test_open_url_allowed_domain(engine, opened):
    r = run(engine, "open_url", {"url": "https://example.com/docs?q=1#top"})
    assert r.ok and opened == ["https://example.com/docs?q=1#top"]
    assert run(engine, "open_url", {"url": "https://EXAMPLE.com"}).ok
    assert run(engine, "open_url", {"url": "https://docs.example.org:443/x"}).ok


@pytest.mark.parametrize("url", [
    "http://example.com",                          # not https
    "https://evil.com",                            # not allowlisted
    "https://example.com.evil.com/",               # suffix trick
    "https://evil.com/example.com",                # allowed name only in the path
    "https://sub.example.com/",                    # sub-domains are not implied
    "https://notexample.com/",
    "https://example.com@evil.com/",               # userinfo trick
    "https://evil.com@example.com/",               # userinfo at all is refused
    "https://user:pw@example.com/",
    "https://example.com:8443/",                   # odd port
    "https://example.com:99999/",
    "https://example.com./",                       # trailing dot
    "https://example.com\\@evil.com/",             # backslash confusion
    "https://exa mple.com/",                       # whitespace
    "https://example.com/\r\nHost: evil.com",      # header injection
    "https://exаmple.com/",                        # Cyrillic 'а' look-alike
    "https:///example.com",                        # empty host
    "https://[::1]/",                              # IP literal not allowlisted
    "javascript:alert(1)", "file:///C:/Windows/win.ini", "ftp://example.com/",
    "//example.com", "example.com", "calc.exe", "ms-settings:", "\\\\evil\\share",
])
def test_open_url_denies_everything_else(engine, opened, url):
    r = run(engine, "open_url", {"url": url})
    assert not r.ok and opened == []


def test_open_url_with_no_allowlist_is_off(engine, opened):
    engine.settings.allowed_domains = []
    assert not run(engine, "open_url", {"url": "https://example.com"}).ok
    assert opened == []


def test_open_url_bad_params(engine, opened):
    for params in ({}, {"url": ""}, {"url": 5}, {"url": "https://example.com", "x": "1"},
                   {"url": "https://example.com/" + "a" * 600}):
        assert not run(engine, "open_url", params).ok
    assert opened == []
    assert check_url("https://example.com", [" Example.COM "]) == "example.com"


# ----------------------------------------------------------------- tail_log
def test_tail_log_last_lines(engine, settings):
    settings_path = settings.allowed_logs["coder"]
    open(settings_path, "w", encoding="utf-8").write("".join(f"row {i}\n" for i in range(500)))
    r = run(engine, "tail_log", {"name": "coder", "lines": "3"})
    assert r.ok and r.data["text"] == "row 497\nrow 498\nrow 499"
    assert r.data["untrusted"] is True
    assert run(engine, "tail_log", {"name": "CODER"}).data["text"].count("\n") == 49  # default 50


def test_tail_log_only_approved_names(engine):
    for name in ("other", "../coder", "C:\\Windows\\win.ini", "coder.log", "..\\..\\x",
                 "/etc/passwd"):
        r = run(engine, "tail_log", {"name": name})
        assert not r.ok and "not an approved log" in r.message, name


def test_tail_log_bad_params(engine):
    for params in ({}, {"name": ""}, {"name": "coder", "lines": "0"},
                   {"name": "coder", "lines": "201"}, {"name": "coder", "lines": "x"},
                   {"name": "coder", "path": "C:\\x"}):
        assert not run(engine, "tail_log", params).ok


def test_tail_log_caps_huge_files_and_lines(engine, settings):
    path = settings.allowed_logs["coder"]
    with open(path, "w", encoding="utf-8") as f:
        f.write("A" * 5_000_000 + "\n")                 # one gigantic line
        f.write("".join(f"{i:04d} " + "b" * 94 + "\n" for i in range(1000)))
        f.write("tail marker\n")
    r = run(engine, "tail_log", {"name": "coder", "lines": "200"})
    # 200 lines x 100 chars would be 20000 chars; the output cap must cut it
    assert r.ok and len(r.data["text"]) <= 8000 and r.data["truncated"]
    assert r.data["text"].endswith("tail marker")
    # a single endless line with no newline at all is cut too
    with open(path, "w", encoding="utf-8") as f:
        f.write("C" * 3_000_000)
    r = run(engine, "tail_log", {"name": "coder"})
    assert r.ok and len(r.data["text"]) == 8000 and r.data["truncated"]


def test_tail_log_strips_terminal_escapes_and_secrets(engine, settings):
    path = settings.allowed_logs["coder"]
    open(path, "w", encoding="utf-8").write(
        "\x1b[31mred\x1b[0m \x00 bell\x07 sk-ant-api03-ABCDEF Bearer tok123\n")
    text = run(engine, "tail_log", {"name": "coder"}).data["text"]
    assert "\x1b" not in text and "\x00" not in text and "\x07" not in text
    assert "ABCDEF" not in text and "tok123" not in text and "red" in text


def test_tail_log_reads_utf16_and_missing_files(engine, settings):
    path = settings.allowed_logs["coder"]
    open(path, "w", encoding="utf-16").write("alpha\r\nবাংলা\r\n")
    assert run(engine, "tail_log", {"name": "coder", "lines": "2"}).data["text"] == "alpha\nবাংলা"
    import os
    os.remove(path)
    r = run(engine, "tail_log", {"name": "coder"})
    assert not r.ok and "does not exist" in r.message


def test_tail_log_content_is_not_written_to_audit(engine, settings):
    open(settings.allowed_logs["coder"], "w", encoding="utf-8").write("PRIVATE-LOG-CONTENT\n")
    run(engine, "tail_log", {"name": "coder"})
    assert "PRIVATE-LOG-CONTENT" not in str(engine.audit.recent(5))
