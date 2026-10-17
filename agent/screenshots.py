"""Read-only access to the screenshots the agent itself took.

The phone may list and download screenshots, nothing else. Every file name is
checked against one strict pattern (the same shape ``take_screenshot``
creates), so a client can never name a path: no separators, no dots other than
the extension, no drive letters, no alternate data streams. The folder and the
final file still go through ``resolve_allowed`` as a second line of defence.
"""
from __future__ import annotations

import io
import re
from pathlib import Path

from .actions import ActionError, resolve_allowed
from .config import Settings

NAME_RE = re.compile(r"^screenshot-[0-9]{8}-[0-9]{6}(?:-[0-9]{1,3})?\.(png|jpg)$")
MAX_BYTES = 12 * 1024 * 1024        # larger files are refused, not streamed
MAX_LISTED = 200
MIN_WIDTH, MAX_WIDTH = 200, 2000
MIME = {"png": "image/png", "jpg": "image/jpeg"}


class ScreenshotError(Exception):
    """Carries an HTTP-ish status so the server can map it."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status, self.message = status, message


def _folder(settings: Settings) -> Path:
    try:
        folder = resolve_allowed(str(settings.screenshots_dir), settings.allowed_roots)
    except ActionError as exc:
        raise ScreenshotError(403, str(exc))
    if not folder.is_dir():
        raise ScreenshotError(404, "There is no screenshots folder yet.")
    return folder


def _is_plain_file(p: Path) -> bool:
    try:
        return p.is_file() and not p.is_symlink()
    except OSError:
        return False


def list_screenshots(settings: Settings) -> list[dict]:
    """Newest first. A missing folder is simply an empty list."""
    try:
        folder = _folder(settings)
    except ScreenshotError as exc:
        if exc.status == 404:
            return []
        raise
    rows = []
    for p in folder.iterdir():
        if NAME_RE.fullmatch(p.name) and _is_plain_file(p):
            st = p.stat()
            rows.append({"name": p.name, "size": st.st_size, "modified": int(st.st_mtime)})
    rows.sort(key=lambda r: (r["modified"], r["name"]), reverse=True)
    return rows[:MAX_LISTED]


def resolve_screenshot(settings: Settings, name: str) -> Path:
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise ScreenshotError(400, "Invalid file name.")
    folder = _folder(settings)
    path = folder / name
    if path.is_symlink() or not path.is_file():
        raise ScreenshotError(404, "No such screenshot.")
    try:
        real = resolve_allowed(str(path), [folder])
    except ActionError:
        raise ScreenshotError(404, "No such screenshot.")
    if real.parent != folder:
        raise ScreenshotError(404, "No such screenshot.")
    return real


def looks_like_image(data: bytes) -> bool:
    """Only real PNG / JPEG bytes are ever served, whatever the file is called."""
    return data.startswith(b"\x89PNG\r\n\x1a\n") or data.startswith(b"\xff\xd8\xff")


def pillow_available() -> bool:
    try:
        import PIL.Image  # noqa: F401
    except ImportError:
        return False
    return True


LOW_WIDTH, LOW_JPEG_QUALITY = 640, 35          # data-saver ("low"): SIM link


def parse_quality(value) -> str:
    """'low' | 'normal'. Anything else is a ScreenshotError (400), never silently guessed."""
    if value is None or value == "":
        return "normal"
    if isinstance(value, str) and value.strip().lower() in ("low", "normal"):
        return value.strip().lower()
    raise ScreenshotError(400, "quality must be 'low' or 'normal'.")


def to_low_jpeg(png_bytes: bytes) -> bytes | None:
    """Downscale + JPEG-compress (data-saver). None when Pillow is missing or the data is bad."""
    if not pillow_available():
        return None
    from PIL import Image

    try:
        Image.MAX_IMAGE_PIXELS = 50_000_000
        with Image.open(io.BytesIO(png_bytes)) as im:
            im = im.convert("RGB")
            if im.width > LOW_WIDTH:
                im = im.resize((LOW_WIDTH, max(1, round(im.height * LOW_WIDTH / im.width))))
            out = io.BytesIO()
            im.save(out, "JPEG", quality=LOW_JPEG_QUALITY, optimize=True)
    except Exception:
        return None
    return out.getvalue()


def load_screenshot(settings: Settings, name: str, width: int | None = None,
                    quality: int | str = 60) -> tuple[bytes, str]:
    """Return (bytes, mime). With Pillow installed and ``width`` given, the image
    is downscaled and sent as JPEG (much smaller on mobile data); without Pillow
    the original file is sent unchanged."""
    path = resolve_screenshot(settings, name)
    if path.stat().st_size > MAX_BYTES:
        raise ScreenshotError(413, "That screenshot is too large to send.")
    data = path.read_bytes()
    if not looks_like_image(data):
        raise ScreenshotError(415, "That file is not a screenshot image.")
    mime = MIME[path.suffix[1:]]
    if isinstance(quality, str):
        if parse_quality(quality) == "low":
            small = to_low_jpeg(data)
            if small is not None and (width is None or width >= LOW_WIDTH):
                return small, "image/jpeg"
            width = LOW_WIDTH if width is None else width
            quality = LOW_JPEG_QUALITY
        else:
            quality = 60
    if width is None or not pillow_available():
        return data, mime
    width = max(MIN_WIDTH, min(int(width), MAX_WIDTH))
    quality = max(20, min(int(quality), 90))
    from PIL import Image

    try:
        Image.MAX_IMAGE_PIXELS = 50_000_000
        with Image.open(io.BytesIO(data)) as im:
            im = im.convert("RGB")
            if im.width > width:
                im = im.resize((width, max(1, round(im.height * width / im.width))))
            out = io.BytesIO()
            im.save(out, "JPEG", quality=quality, optimize=True)
    except Exception:  # a corrupt file: fall back to the original bytes
        return data, mime
    return out.getvalue(), "image/jpeg"


def prune(folder: Path, keep: int) -> int:
    """Delete the oldest agent-made screenshots beyond ``keep``. Only files that
    match NAME_RE, are regular (not links) and sit directly in ``folder``."""
    keep = max(1, int(keep))
    files = [p for p in folder.iterdir() if NAME_RE.fullmatch(p.name) and _is_plain_file(p)]
    files.sort(key=lambda p: (p.stat().st_mtime, p.name), reverse=True)
    removed = 0
    for p in files[keep:]:
        try:
            p.unlink()
            removed += 1
        except OSError:
            pass
    return removed
