import os
import sys
import time

import pytest
from fastapi.testclient import TestClient

from agent import screenshots
from agent.server import create_app

PNG = b"\x89PNG\r\n\x1a\nfake"


@pytest.fixture
def http(engine, settings):
    return TestClient(create_app(settings, engine))


@pytest.fixture
def auth(http, engine):
    code = engine.pairing.create_code()
    token = http.post("/pair", json={"code": code, "device_name": "phone"}).json()["token"]
    return {"Authorization": f"Bearer {token}"}


def put(settings, name, data=PNG, age=0):
    settings.screenshots_dir.mkdir(parents=True, exist_ok=True)
    p = settings.screenshots_dir / name
    p.write_bytes(data)
    t = time.time() - age
    os.utime(p, (t, t))
    return p


# ------------------------------------------------------------------ auth
def test_screenshots_require_auth(http, settings):
    put(settings, "screenshot-20260101-100000.png")
    assert http.get("/screenshots").status_code == 401
    assert http.get("/screenshots/screenshot-20260101-100000.png").status_code == 401
    bad = {"Authorization": "Bearer nope"}
    assert http.get("/screenshots", headers=bad).status_code == 401
    assert http.get("/screenshots/screenshot-20260101-100000.png", headers=bad).status_code == 401


def test_screenshots_are_rate_limited(http, auth, settings, engine):
    engine.limiter.limit = 3
    codes = [http.get("/screenshots", headers=auth).status_code for _ in range(6)]
    assert 429 in codes


# ------------------------------------------------------------------ happy path
def test_list_and_download(http, auth, settings):
    put(settings, "screenshot-20260101-100000.png", age=100)
    put(settings, "screenshot-20260101-100100.png", age=10)
    put(settings, "notes.txt", b"x")               # not an agent screenshot: invisible
    body = http.get("/screenshots", headers=auth).json()
    assert [f["name"] for f in body["files"]] == [
        "screenshot-20260101-100100.png", "screenshot-20260101-100000.png"]
    r = http.get("/screenshots/screenshot-20260101-100100.png", headers=auth)
    assert r.status_code == 200 and r.content == PNG
    assert r.headers["content-type"] == "image/png"
    assert r.headers["cache-control"] == "no-store"


def test_missing_folder_lists_empty_and_404s(http, auth, settings):
    assert not settings.screenshots_dir.exists()
    assert http.get("/screenshots", headers=auth).json()["files"] == []
    assert http.get("/screenshots/screenshot-20260101-100000.png", headers=auth).status_code == 404


def test_folder_outside_allowed_roots_is_refused(http, auth, settings, tmp_path):
    settings.screenshots_dir = tmp_path / "elsewhere"
    settings.screenshots_dir.mkdir()
    put(settings, "screenshot-20260101-100000.png")
    assert http.get("/screenshots", headers=auth).status_code == 403
    assert http.get("/screenshots/screenshot-20260101-100000.png", headers=auth).status_code == 403


# ------------------------------------------------------------------ name guard
BAD_NAMES = [
    "..%2f..%2fsecret.txt", "..%5cwindows%5cwin.ini", "%2e%2e%2fx.png",
    "screenshot-20260101-100000.png%00.txt", "screenshot-20260101-100000.png.txt",
    "screenshot-20260101-100000.gif", "screenshot-20260101-100000.PNG",
    "screenshot-20260101-100000.png::$DATA", "screenshot-20260101-100000.png.",
    "screenshot-20260101-100000.png%20", "SCREENSHOT-20260101-100000.png",
    "screenshot-2026-1-1.png", "C:%5cwindows%5cwin.ini", "screenshot-20260101-100000.exe",
    "screenshot-20260101-100000~1.png", "%5c%5cserver%5cshare%5cscreenshot-20260101-100000.png",
    "screenshot-20260101-100000-12345.png",
]


@pytest.mark.parametrize("name", BAD_NAMES)
def test_bad_names_are_rejected(http, auth, settings, name):
    put(settings, "screenshot-20260101-100000.png")
    (settings.screenshots_dir.parent / "secret.txt").write_text("top secret")
    r = http.get(f"/screenshots/{name}", headers=auth)
    assert r.status_code in (400, 404, 405)
    assert b"top secret" not in r.content


def test_wrong_extension_files_are_never_served(http, auth, settings):
    put(settings, "screenshot-20260101-100000.txt", b"secret")
    put(settings, "screenshot-20260101-100001.exe", b"MZ")
    names = [f["name"] for f in http.get("/screenshots", headers=auth).json()["files"]]
    assert names == []
    assert http.get("/screenshots/screenshot-20260101-100000.txt", headers=auth).status_code == 400


def test_direct_name_checks():
    from agent.config import Settings
    s = Settings()
    for bad in ("", "a/b.png", "..", "screenshot-20260101-100000.png/", None, 5):
        with pytest.raises(screenshots.ScreenshotError) as ei:
            screenshots.resolve_screenshot(s, bad)
        assert ei.value.status == 400


@pytest.mark.skipif(sys.platform != "win32", reason="NTFS reparse behaviour")
def test_symlink_is_not_followed(http, auth, settings, tmp_path):
    outside = tmp_path / "outside.png"
    outside.write_bytes(b"secret")
    settings.screenshots_dir.mkdir(parents=True, exist_ok=True)
    link = settings.screenshots_dir / "screenshot-20260101-100000.png"
    try:
        link.symlink_to(outside)
    except OSError:
        pytest.skip("no symlink privilege")
    assert http.get("/screenshots/screenshot-20260101-100000.png", headers=auth).status_code == 404
    assert http.get("/screenshots", headers=auth).json()["files"] == []


def test_symlink_not_followed_posix_style(settings, tmp_path, monkeypatch):
    """Platform independent: a file that reports is_symlink() is refused."""
    p = put(settings, "screenshot-20260101-100000.png")
    from pathlib import Path
    real = Path.is_symlink
    monkeypatch.setattr(Path, "is_symlink", lambda self: self.name == p.name or real(self))
    with pytest.raises(screenshots.ScreenshotError) as ei:
        screenshots.resolve_screenshot(settings, p.name)
    assert ei.value.status == 404


# ------------------------------------------------------------------ size cap
def test_oversized_file_is_refused(http, auth, settings, monkeypatch):
    put(settings, "screenshot-20260101-100000.png", PNG + b"0" * 2048)
    monkeypatch.setattr(screenshots, "MAX_BYTES", 1024)
    assert http.get("/screenshots/screenshot-20260101-100000.png", headers=auth).status_code == 413


# ------------------------------------------------------------------ compression
def test_width_param_without_pillow_returns_original(http, auth, settings, monkeypatch):
    put(settings, "screenshot-20260101-100000.png")
    monkeypatch.setattr(screenshots, "pillow_available", lambda: False)
    r = http.get("/screenshots/screenshot-20260101-100000.png?width=400", headers=auth)
    assert r.status_code == 200 and r.content == PNG
    assert http.get("/screenshots", headers=auth).json()["compression"] is False


def test_width_param_with_pillow_gives_small_jpeg(http, auth, settings):
    pytest.importorskip("PIL")
    from agent.screen import encode_png
    w, h = 800, 400
    png = encode_png(w, h, bytes([200, 100, 50, 255]) * (w * h))
    put(settings, "screenshot-20260101-100000.png", png)
    r = http.get("/screenshots/screenshot-20260101-100000.png?width=300&quality=50", headers=auth)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert r.content[:3] == b"\xff\xd8\xff"


def test_corrupt_image_falls_back_to_original(settings, monkeypatch):
    put(settings, "screenshot-20260101-100000.png", PNG)
    monkeypatch.setattr(screenshots, "pillow_available", lambda: True)
    pytest.importorskip("PIL")
    data, mime = screenshots.load_screenshot(settings, "screenshot-20260101-100000.png", 400)
    assert data == PNG and mime == "image/png"


# ------------------------------------------------------------------ auto delete
def test_take_screenshot_keeps_only_the_newest(engine, settings):
    settings.screenshot_keep = 3
    for i in range(6):
        put(settings, f"screenshot-20260101-10000{i}.png", age=1000 - i)
    keepsake = settings.screenshots_dir / "my-own-file.png"      # not ours: never deleted
    keepsake.write_bytes(b"mine")
    r = engine.run("take_screenshot", {}, actor="t", via="test")
    assert r.ok
    ours = sorted(p.name for p in settings.screenshots_dir.glob("screenshot-*.png"))
    assert len(ours) == 3
    assert r.data["file"] in ours
    assert "screenshot-20260101-100000.png" not in ours      # oldest gone
    assert keepsake.exists()


def test_prune_ignores_links_and_other_names(settings):
    put(settings, "screenshot-20260101-100000.png", age=500)
    put(settings, "screenshot-20260101-100001.png", age=400)
    put(settings, "readme.txt")
    removed = screenshots.prune(settings.screenshots_dir, 1)
    assert removed == 1
    assert (settings.screenshots_dir / "readme.txt").exists()


def test_bad_keep_value_falls_back(engine, settings):
    settings.screenshot_keep = "lots"            # wrong type in config.json
    assert engine.run("take_screenshot", {}, actor="t", via="test").ok
