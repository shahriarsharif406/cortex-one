"""Screenshot of the whole virtual desktop as a PNG, with no third-party
dependency (Windows GDI through ctypes + a tiny PNG encoder).

Only ``grab_png`` is used by the agent; the action decides the file name and
folder, never the caller.
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path


def encode_png(width: int, height: int, bgra: bytes) -> bytes:
    """Encode top-down 32-bit BGRA pixels as an RGB PNG."""
    if len(bgra) != width * height * 4:
        raise ValueError("pixel buffer has the wrong size")
    rgb = bytearray(width * height * 3)
    rgb[0::3] = bgra[2::4]
    rgb[1::3] = bgra[1::4]
    rgb[2::3] = bgra[0::4]
    stride = width * 3
    raw = bytearray()
    for row in range(height):
        raw.append(0)  # filter type 0 (none)
        raw += rgb[row * stride:(row + 1) * stride]

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 3))
            + chunk(b"IEND", b""))


def grab_png(path: Path) -> None:
    """Write a screenshot to ``path``. Raises OSError if the screen is unavailable."""
    import ctypes
    from ctypes import wintypes

    windll = getattr(ctypes, "windll", None)
    if windll is None:
        raise OSError("screenshots need Windows")
    user32, gdi32 = windll.user32, windll.gdi32
    H = wintypes.HANDLE
    user32.GetDC.restype, user32.GetDC.argtypes = H, [H]
    user32.ReleaseDC.argtypes = [H, H]
    gdi32.CreateCompatibleDC.restype, gdi32.CreateCompatibleDC.argtypes = H, [H]
    gdi32.CreateCompatibleBitmap.restype = H
    gdi32.CreateCompatibleBitmap.argtypes = [H, ctypes.c_int, ctypes.c_int]
    gdi32.SelectObject.restype, gdi32.SelectObject.argtypes = H, [H, H]
    gdi32.BitBlt.argtypes = [H, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                             H, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
    gdi32.GetDIBits.argtypes = [H, H, wintypes.UINT, wintypes.UINT, ctypes.c_void_p,
                                ctypes.c_void_p, wintypes.UINT]
    gdi32.DeleteObject.argtypes = [H]
    gdi32.DeleteDC.argtypes = [H]

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
                    ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
                    ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                    ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                    ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                    ("biClrImportant", wintypes.DWORD)]

    try:
        user32.SetProcessDPIAware()
    except Exception:
        pass
    x, y = user32.GetSystemMetrics(76), user32.GetSystemMetrics(77)    # virtual screen origin
    w, h = user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)    # virtual screen size
    if w <= 0 or h <= 0 or w * h > 40_000_000:
        raise OSError("no usable screen")

    screen_dc = user32.GetDC(None)
    if not screen_dc:
        raise OSError("cannot access the screen (locked or no desktop session)")
    mem_dc = bitmap = old = None
    try:
        mem_dc = gdi32.CreateCompatibleDC(screen_dc)
        bitmap = gdi32.CreateCompatibleBitmap(screen_dc, w, h)
        if not mem_dc or not bitmap:
            raise OSError("cannot allocate the screenshot bitmap")
        old = gdi32.SelectObject(mem_dc, bitmap)
        # SRCCOPY | CAPTUREBLT (also captures layered windows)
        if not gdi32.BitBlt(mem_dc, 0, 0, w, h, screen_dc, x, y, 0x00CC0020 | 0x40000000):
            raise OSError("screen capture failed (is the screen locked?)")
        header = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0)
        buf = ctypes.create_string_buffer(w * h * 4)
        if not gdi32.GetDIBits(mem_dc, bitmap, 0, h, buf, ctypes.byref(header), 0):
            raise OSError("cannot read screen pixels")
        data = encode_png(w, h, buf.raw)
    finally:
        if old and mem_dc:
            gdi32.SelectObject(mem_dc, old)
        if bitmap:
            gdi32.DeleteObject(bitmap)
        if mem_dc:
            gdi32.DeleteDC(mem_dc)
        user32.ReleaseDC(None, screen_dc)
    Path(path).write_bytes(data)
