"""Validation of images sent with an AI task (phase 5).

The phone shrinks pictures and strips their metadata BEFORE upload. The agent does not trust
that: it checks everything itself and rejects on doubt. It never silently strips or "fixes" an
image: either the picture is accepted exactly as sent, or the whole task is refused.

Accepted: JPEG or PNG, at most 3 per task, at most 1.5 MB each after decoding, consistent
magic bytes / declared type / structure, sane dimensions, and no metadata blocks (EXIF, XMP,
text chunks). Image bytes are never logged, audited or stored.
"""
from __future__ import annotations

import base64
import binascii
import struct
from dataclasses import dataclass

MAX_IMAGES = 3
MAX_IMAGE_BYTES = 1_500_000
MAX_B64_CHARS = (MAX_IMAGE_BYTES * 4) // 3 + 8
MAX_SIDE = 4096                  # pixels
MAX_PIXELS = 12_000_000
MIN_SIDE = 8
ALLOWED_TYPES = ("image/jpeg", "image/png")

_PNG_SIG = b"\x89PNG\r\n\x1a\n"
# PNG chunks that may appear; anything else (eXIf, tEXt, zTXt, iTXt, tIME, ...) is metadata
_PNG_OK = {b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS", b"gAMA", b"cHRM", b"sRGB", b"pHYs",
           b"sBIT", b"bKGD", b"iCCP"}
# JPEG markers that carry metadata or application data
_JPEG_APP_ALLOWED = {0xE0}        # JFIF only; APP1 (EXIF/XMP), APP2.., APP13 (Photoshop) are refused
_JPEG_SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


class ImageError(ValueError):
    """The image is refused. The message is safe to show (never contains image data)."""


@dataclass(frozen=True)
class ImageBlock:
    media_type: str
    data_b64: str
    width: int
    height: int
    size: int

    @property
    def est_tokens(self) -> int:
        """Anthropic's rule of thumb is about width*height/750 tokens per image."""
        return max(1, (self.width * self.height) // 750)


def _png_info(data: bytes) -> tuple[int, int]:
    if not data.startswith(_PNG_SIG):
        raise ImageError("The PNG file is damaged.")
    pos, width, height, seen_iend, first = 8, 0, 0, False, True
    while pos + 12 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        if length > len(data) or pos + 12 + length > len(data):
            raise ImageError("The PNG file is damaged.")
        if first and kind != b"IHDR":
            raise ImageError("The PNG file is damaged.")
        if kind not in _PNG_OK:
            raise ImageError("The PNG contains metadata. Remove it first (the app does this).")
        if kind == b"IHDR":
            if length != 13:
                raise ImageError("The PNG file is damaged.")
            width, height = struct.unpack(">II", data[pos + 8:pos + 16])
        first = False
        pos += 12 + length
        if kind == b"IEND":
            seen_iend = True
            break
    if not seen_iend or pos != len(data):
        raise ImageError("The PNG file is damaged or has extra data after its end.")
    return width, height


def _jpeg_info(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\xff\xd8\xff") or not data.endswith(b"\xff\xd9"):
        raise ImageError("The JPEG file is damaged.")
    pos, width, height = 2, 0, 0
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            raise ImageError("The JPEG file is damaged.")
        marker = data[pos + 1]
        if marker == 0xFF:            # fill byte
            pos += 1
            continue
        if marker == 0xD9:
            break
        if 0xD0 <= marker <= 0xD7 or marker in (0x01, 0x00):
            pos += 2
            continue
        length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
        if length < 2 or pos + 2 + length > len(data):
            raise ImageError("The JPEG file is damaged.")
        if 0xE0 <= marker <= 0xEF and marker not in _JPEG_APP_ALLOWED:
            raise ImageError("The JPEG contains metadata (EXIF/XMP). Remove it first (the app does this).")
        if marker == 0xFE:
            raise ImageError("The JPEG contains a comment block. Remove it first.")
        if marker in _JPEG_SOF:
            if length < 8:
                raise ImageError("The JPEG file is damaged.")
            height, width = struct.unpack(">HH", data[pos + 5:pos + 9])
        if marker == 0xDA:            # start of scan: the entropy-coded data follows
            break
        pos += 2 + length
    if not width or not height:
        raise ImageError("The JPEG file is damaged.")
    return width, height


def validate_image(media_type: object, data_b64: object) -> ImageBlock:
    """Return the image if it passes every check, else raise ImageError."""
    if media_type not in ALLOWED_TYPES:
        raise ImageError("Only JPEG and PNG pictures are accepted.")
    if not isinstance(data_b64, str) or not data_b64:
        raise ImageError("The picture is empty.")
    if len(data_b64) > MAX_B64_CHARS:
        raise ImageError("The picture is too large (max 1.5 MB after shrinking).")
    try:
        data = base64.b64decode(data_b64, validate=True)
    except (binascii.Error, ValueError):
        raise ImageError("The picture data is not valid.")
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ImageError("The picture is too large (max 1.5 MB after shrinking).")
    is_png = data.startswith(_PNG_SIG)
    is_jpeg = data.startswith(b"\xff\xd8\xff")
    if (media_type == "image/png") != is_png or (media_type == "image/jpeg") != is_jpeg:
        raise ImageError("The picture type does not match its content.")
    width, height = _png_info(data) if is_png else _jpeg_info(data)
    if not (MIN_SIDE <= width <= MAX_SIDE and MIN_SIDE <= height <= MAX_SIDE) \
            or width * height > MAX_PIXELS:
        raise ImageError(f"The picture size is not acceptable (max {MAX_SIDE} pixels a side).")
    return ImageBlock(media_type, base64.b64encode(data).decode("ascii"), width, height, len(data))


def validate_images(items: object) -> list[ImageBlock]:
    """A list of {"media_type", "data"} dicts. Raises ImageError; accepts at most MAX_IMAGES."""
    if items is None or items == []:
        return []
    if not isinstance(items, (list, tuple)):
        raise ImageError("The pictures are not in a valid form.")
    if len(items) > MAX_IMAGES:
        raise ImageError(f"At most {MAX_IMAGES} pictures can be sent with one task.")
    out = []
    for item in items:
        if not isinstance(item, dict) or set(item) - {"media_type", "data"}:
            raise ImageError("The pictures are not in a valid form.")
        out.append(validate_image(item.get("media_type"), item.get("data")))
    return out


def content_blocks(text: str, images: list[ImageBlock]) -> list[dict]:
    """Messages API content for the first user turn: the pictures first, then the text."""
    blocks: list[dict] = [{"type": "image", "source": {"type": "base64", "media_type": i.media_type,
                                                       "data": i.data_b64}} for i in images]
    blocks.append({"type": "text", "text": text})
    return blocks
