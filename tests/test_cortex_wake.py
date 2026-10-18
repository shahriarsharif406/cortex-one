"""Cortex Wake: the Python reference, the shared vectors, and the C++ header (via WebAssembly).

The Dart side is tested by mobile/test/wake_test.dart against the same JSON file.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REF_PATH = ROOT / "docs" / "cortex-wake" / "reference.py"
VECTORS = ROOT / "docs" / "cortex-wake" / "test_vectors.json"

spec = importlib.util.spec_from_file_location("cw_reference", REF_PATH)
ref = importlib.util.module_from_spec(spec)
sys.modules["cw_reference"] = ref
spec.loader.exec_module(ref)


def vectors():
    return json.loads(VECTORS.read_text(encoding="utf-8"))


def test_committed_vectors_are_what_the_reference_generates():
    assert vectors() == ref.generate()


def test_reference_self_check_passes_on_committed_file():
    assert ref.self_check(vectors()) == []


def test_reference_self_check_catches_tampering():
    v = vectors()
    v["parse_cases"][0]["expect"] = "bad_tag"
    assert ref.self_check(v)
    v = vectors()
    f = bytearray(bytes.fromhex(v["commands"][0]["frame_hex"]))
    f[8] ^= 1
    v["commands"][0]["frame_hex"] = bytes(f).hex()
    assert ref.self_check(v)


def test_rfc4231_cases_are_really_in_the_file():
    assert len(vectors()["hmac_sha256_rfc4231"]) == 3


KEY, DEV = ref.KEY, ref.DEVICE_ID


def frame(counter=10, cmd=ref.CMD_PRESS, args=b"\x01\x90"):
    return ref.build_command(KEY, DEV, counter, cmd, args)


def test_every_single_byte_change_is_rejected():
    good = frame()
    for i in range(len(good)):
        bad = bytearray(good)
        bad[i] ^= 0x01
        res = ref.parse_command(bytes(bad), KEY, DEV, 9)[0]
        assert res != ref.OK, f"byte {i} could be changed without detection"


def test_a_frame_is_accepted_once_per_counter_state():
    f = frame(10)
    assert ref.parse_command(f, KEY, DEV, 9)[0] == ref.OK
    assert ref.parse_command(f, KEY, DEV, 10)[0] == ref.REPLAY      # after the device stored 10
    assert ref.parse_command(f, KEY, DEV, 11)[0] == ref.REPLAY


def test_counter_window():
    f = frame(ref.MAX_JUMP + 5)
    assert ref.parse_command(f, KEY, DEV, 5)[0] == ref.OK
    assert ref.parse_command(f, KEY, DEV, 4)[0] == ref.JUMP


def test_tag_is_checked_before_the_counter():
    bad = bytearray(frame(10))
    bad[-1] ^= 1
    # even with a wildly wrong counter the verdict is bad_tag: no counter oracle for a forger
    assert ref.parse_command(bytes(bad), KEY, DEV, 4_000_000)[0] == ref.BAD_TAG


def test_a_command_never_verifies_as_an_answer_and_vice_versa():
    cmd = frame(5, ref.CMD_STATE, b"")
    assert ref.parse_response(cmd, KEY, DEV)[0] is False
    resp = ref.build_response(KEY, DEV, 0, 5, 0, 0)
    assert ref.parse_command(resp, KEY, DEV, 0)[0] != ref.OK


def test_press_limits_are_the_documented_ones():
    assert (ref.MIN_PRESS_MS, ref.MAX_PRESS_MS) == (100, 1500)
    text = (ROOT / "firmware" / "cortex-wake" / "include" / "cw_auth.h").read_text(encoding="utf-8")
    assert "kMaxPressMs = 1500" in text and "kMinPressMs = 100" in text
    assert "kMaxJump = 100000" in text


def test_firmware_sources_do_not_contain_a_real_key():
    for p in (ROOT / "firmware" / "cortex-wake").rglob("*"):
        if p.is_file() and p.suffix in {".h", ".cpp", ".ini", ".md"}:
            assert p.name != "secrets.h"
    example = (ROOT / "firmware" / "cortex-wake" / "include" / "secrets.example.h").read_text(encoding="utf-8")
    assert "0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00" in example
    gi = (ROOT / "firmware" / "cortex-wake" / ".gitignore").read_text(encoding="utf-8")
    assert "include/secrets.h" in gi


def test_firmware_main_follows_the_documented_order():
    src = (ROOT / "firmware" / "cortex-wake" / "src" / "main.cpp").read_text(encoding="utf-8")
    assert src.index("parse_command") < src.index('prefs.putUInt("ctr"') < src.index("case cw::PRESS")
    assert "press_ms_ok" in src and "PRESS_WATCHDOG_MS" in src and "calOpenUntil" in src
    assert "NOT COMPILED" in src      # honesty banner must stay until it is built on hardware


@pytest.mark.skipif(shutil.which("node") is None, reason="needs Node.js")
def test_cpp_header_passes_the_same_vectors_via_wasm():
    proc = subprocess.run([sys.executable, str(ROOT / "firmware" / "cortex-wake" / "test" / "run_cpp_vectors.py")],
                          capture_output=True, text=True, timeout=240)
    if proc.returncode == 77:
        pytest.skip("no clang with wasm32 + wasm-ld (set CW_CLANG_DIR)")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "0 failures" in proc.stdout


def test_led_classifier_vectors_and_rules():
    cases = vectors()["led_cases"]
    assert len(cases) >= 10
    for c in cases:
        assert list(ref.classify_led(c["lo"], c["hi"])) == [c["state"], c["raw4"]]
    # steady dark = off, steady bright = on, swinging = blink, nonsense = unknown
    assert ref.classify_led(0, 40)[0] == ref.LAPTOP_OFF
    assert ref.classify_led(3000, 3100)[0] == ref.LAPTOP_ON
    assert ref.classify_led(100, 3000)[0] == ref.LAPTOP_BLINK
    assert ref.classify_led(2000, 100)[0] == ref.LAPTOP_UNKNOWN
    # the answer byte carries state + raw level and still verifies as a normal frame
    b = ref.laptop_byte(ref.LAPTOP_BLINK, 3)
    ok, status, counter, laptop, servo = ref.parse_response(
        ref.build_response(KEY, DEV, ref.ST_OK, 5, b, 0), KEY, DEV)
    assert ok and laptop & 15 == ref.LAPTOP_BLINK and laptop >> 4 == 3


def test_led_vectors_tampering_is_caught():
    v = vectors()
    v["led_cases"][0]["state"] = 1
    assert ref.self_check(v)
