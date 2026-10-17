#!/usr/bin/env python3
"""Cortex Wake: reference implementation of the BLE frame authentication, and the generator /
checker of docs/cortex-wake/test_vectors.json.

    python docs/cortex-wake/reference.py --write    # regenerate the vectors file
    python docs/cortex-wake/reference.py --check    # verify the committed file (exit 1 if different)

The same logic exists in Dart (mobile/lib/wake/cw_protocol.dart) and C++
(firmware/cortex-wake/include/cw_auth.h). All three must pass the same vectors.
See PROTOCOL.md for the frame layout.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import struct
import sys
from pathlib import Path

VERSION = 1
TAG_LEN = 16
MAX_JUMP = 100_000               # a new counter may be at most this far ahead of the stored one
MAX_PRESS_MS = 1500              # firmware cap (PRESS beyond this is refused, never clamped)
MIN_PRESS_MS = 100

CMD_PRESS, CMD_STATE, CMD_CALIBRATE, CMD_PING = 1, 2, 3, 4
ARGS_LEN = {CMD_PRESS: 2, CMD_STATE: 0, CMD_CALIBRATE: 2, CMD_PING: 0}

ST_OK, ST_BAD_ARGS, ST_BUSY, ST_CAL_LOCKED, ST_RATE = 0, 1, 2, 3, 4

# parse results
OK, BAD_LENGTH, BAD_VERSION, BAD_CMD, BAD_TAG, REPLAY, JUMP = (
    "ok", "bad_length", "bad_version", "bad_cmd", "bad_tag", "replay", "jump")


def mac(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def command_tag(key: bytes, device_id: bytes, counter: int, cmd: int, args: bytes) -> bytes:
    msg = device_id + struct.pack(">I", counter) + bytes([cmd]) + args
    return mac(key, msg)[:TAG_LEN]


def build_command(key: bytes, device_id: bytes, counter: int, cmd: int, args: bytes = b"") -> bytes:
    body = bytes([VERSION, cmd]) + struct.pack(">I", counter) + args
    return body + command_tag(key, device_id, counter, cmd, args)


def parse_command(frame: bytes, key: bytes, device_id: bytes, stored_counter: int):
    """Returns (result, cmd, counter, args). Anything but OK means: ignore the frame, change nothing."""
    if len(frame) < 6 + TAG_LEN:
        return BAD_LENGTH, 0, 0, b""
    if frame[0] != VERSION:
        return BAD_VERSION, 0, 0, b""
    cmd = frame[1]
    if cmd not in ARGS_LEN:
        return BAD_CMD, cmd, 0, b""
    if len(frame) != 6 + ARGS_LEN[cmd] + TAG_LEN:
        return BAD_LENGTH, cmd, 0, b""
    counter = struct.unpack(">I", frame[2:6])[0]
    args = frame[6:6 + ARGS_LEN[cmd]]
    tag = frame[6 + ARGS_LEN[cmd]:]
    if not hmac.compare_digest(tag, command_tag(key, device_id, counter, cmd, args)):
        return BAD_TAG, cmd, counter, args          # checked BEFORE the counter: no oracle
    if counter <= stored_counter:
        return REPLAY, cmd, counter, args
    if counter - stored_counter > MAX_JUMP:
        return JUMP, cmd, counter, args
    return OK, cmd, counter, args


def response_tag(key: bytes, device_id: bytes, status: int, counter: int, laptop: int, servo: int) -> bytes:
    msg = device_id + b"R" + bytes([VERSION, status]) + struct.pack(">I", counter) + bytes([laptop, servo])
    return mac(key, msg)[:TAG_LEN]


def build_response(key: bytes, device_id: bytes, status: int, counter: int, laptop: int, servo: int) -> bytes:
    body = bytes([VERSION, status]) + struct.pack(">I", counter) + bytes([laptop, servo])
    return body + response_tag(key, device_id, status, counter, laptop, servo)


def parse_response(frame: bytes, key: bytes, device_id: bytes):
    """(ok, status, counter, laptop, servo). ok is False for anything that does not verify."""
    if len(frame) != 8 + TAG_LEN or frame[0] != VERSION:
        return False, 0, 0, 0, 0
    status, = frame[1:2]
    counter, = struct.unpack(">I", frame[2:6])
    laptop, servo = frame[6], frame[7]
    good = hmac.compare_digest(frame[8:], response_tag(key, device_id, status, counter, laptop, servo))
    return good, status, counter, laptop, servo


# ----------------------------------------------------------------- vectors
KEY = bytes(range(32))
DEVICE_ID = bytes.fromhex("a1b2c3d4e5f60718")

# RFC 4231 test cases 1, 2, 3 (HMAC-SHA-256): proof that the primitive itself is right
RFC4231 = [
    ("0b" * 20, "4869205468657265",
     "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
    ("4a656665", "7768617420646f2079612077616e7420666f72206e6f7468696e673f",
     "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
    ("aa" * 20, "dd" * 50,
     "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
]


def generate() -> dict:
    cmds = []

    def add(name, counter, cmd, args=b""):
        f = build_command(KEY, DEVICE_ID, counter, cmd, args)
        cmds.append({"name": name, "counter": counter, "cmd": cmd, "args_hex": args.hex(),
                     "frame_hex": f.hex()})

    add("press_400ms", 1, CMD_PRESS, struct.pack(">H", 400))
    add("press_max", 2, CMD_PRESS, struct.pack(">H", MAX_PRESS_MS))
    add("state", 3, CMD_STATE)
    add("ping", 4, CMD_PING)
    add("calibrate_20_70", 5, CMD_CALIBRATE, bytes([20, 70]))
    add("press_big_counter", 4_000_000_000, CMD_PRESS, struct.pack(">H", 400))

    good = build_command(KEY, DEVICE_ID, 10, CMD_PRESS, struct.pack(">H", 400))
    far = build_command(KEY, DEVICE_ID, 2 * MAX_JUMP, CMD_PRESS, struct.pack(">H", 400))
    flipped_tag = bytearray(good)
    flipped_tag[-1] ^= 1
    flipped_arg = bytearray(good)
    flipped_arg[6] ^= 1                       # change the press time: tag no longer matches
    other_dev = build_command(KEY, bytes.fromhex("0000000000000001"), 10, CMD_PRESS, struct.pack(">H", 400))
    other_key = build_command(bytes(32), DEVICE_ID, 10, CMD_PRESS, struct.pack(">H", 400))
    unknown_cmd = bytearray(good)
    unknown_cmd[1] = 9
    bad_version = bytearray(good)
    bad_version[0] = 2
    parse = [
        ("good_next_counter", good, 9, OK),
        ("good_jump_to_limit", far, MAX_JUMP, OK),
        ("replay_same_counter", good, 10, REPLAY),
        ("replay_lower_counter", good, 11, REPLAY),
        ("jump_too_far", far, MAX_JUMP - 1, JUMP),
        ("flipped_tag_bit", bytes(flipped_tag), 9, BAD_TAG),
        ("flipped_argument_bit", bytes(flipped_arg), 9, BAD_TAG),
        ("other_device_id", other_dev, 9, BAD_TAG),
        ("other_key", other_key, 9, BAD_TAG),
        ("unknown_command", bytes(unknown_cmd), 9, BAD_CMD),
        ("bad_version", bytes(bad_version), 9, BAD_VERSION),
        ("too_short", good[:10], 9, BAD_LENGTH),
        ("empty", b"", 9, BAD_LENGTH),
        ("extra_byte", good + b"\x00", 9, BAD_LENGTH),
        ("missing_byte", good[:-1], 9, BAD_LENGTH),
        # a bad tag is reported as bad_tag even when the counter is also wrong: no counter oracle
        ("bad_tag_and_old_counter", bytes(flipped_tag), 50, BAD_TAG),
    ]
    resp = []
    for name, status, counter, laptop, servo in [
            ("ok_laptop_off", ST_OK, 7, 0, 0), ("ok_laptop_on", ST_OK, 8, 1, 0),
            ("busy", ST_BUSY, 9, 2, 1), ("bad_args", ST_BAD_ARGS, 10, 2, 0),
            ("cal_locked", ST_CAL_LOCKED, 11, 2, 0), ("rate", ST_RATE, 12, 0, 0)]:
        f = build_response(KEY, DEVICE_ID, status, counter, laptop, servo)
        resp.append({"name": name, "status": status, "counter": counter, "laptop": laptop,
                     "servo": servo, "frame_hex": f.hex()})
    bad_resp = bytearray(bytes.fromhex(resp[0]["frame_hex"]))
    bad_resp[2] ^= 1

    return {
        "comment": "Generated by docs/cortex-wake/reference.py; do not edit by hand. "
                   "Dart, Python and C++ must all pass these.",
        "version": VERSION,
        "constants": {"tag_len": TAG_LEN, "max_jump": MAX_JUMP, "max_press_ms": MAX_PRESS_MS,
                      "min_press_ms": MIN_PRESS_MS},
        "key_hex": KEY.hex(),
        "device_id_hex": DEVICE_ID.hex(),
        "hmac_sha256_rfc4231": [{"key_hex": k, "msg_hex": m, "mac_hex": t} for k, m, t in RFC4231],
        "commands": cmds,
        "parse_cases": [{"name": n, "frame_hex": f.hex(), "stored_counter": s, "expect": e}
                        for n, f, s, e in parse],
        "responses": resp,
        "bad_responses": [{"name": "flipped_counter_bit", "frame_hex": bytes(bad_resp).hex()},
                          {"name": "truncated", "frame_hex": resp[0]["frame_hex"][:-2]}],
    }


def dump(vectors: dict) -> str:
    return json.dumps(vectors, indent=2) + "\n"


def self_check(v: dict) -> list[str]:
    """Re-verify the data of a vectors dict with the reference code. Returns problems."""
    problems = []
    key, dev = bytes.fromhex(v["key_hex"]), bytes.fromhex(v["device_id_hex"])
    for t in v["hmac_sha256_rfc4231"]:
        if mac(bytes.fromhex(t["key_hex"]), bytes.fromhex(t["msg_hex"])).hex() != t["mac_hex"]:
            problems.append("rfc4231 mismatch")
    for c in v["commands"]:
        frame = bytes.fromhex(c["frame_hex"])
        res, cmd, counter, args = parse_command(frame, key, dev, c["counter"] - 1)
        if (res, cmd, counter, args.hex()) != (OK, c["cmd"], c["counter"], c["args_hex"]):
            problems.append(f"command {c['name']}: {res}")
    for p in v["parse_cases"]:
        res = parse_command(bytes.fromhex(p["frame_hex"]), key, dev, p["stored_counter"])[0]
        if res != p["expect"]:
            problems.append(f"parse {p['name']}: {res} != {p['expect']}")
    for r in v["responses"]:
        ok, status, counter, laptop, servo = parse_response(bytes.fromhex(r["frame_hex"]), key, dev)
        if not (ok and (status, counter, laptop, servo) == (r["status"], r["counter"], r["laptop"], r["servo"])):
            problems.append(f"response {r['name']}")
    for r in v["bad_responses"]:
        if parse_response(bytes.fromhex(r["frame_hex"]), key, dev)[0]:
            problems.append(f"bad response {r['name']} verified")
    return problems


def main(argv: list[str]) -> int:
    path = Path(__file__).with_name("test_vectors.json")
    fresh = generate()
    problems = self_check(fresh)
    if problems:
        print("reference self-check failed:", problems, file=sys.stderr)
        return 1
    if "--write" in argv:
        path.write_text(dump(fresh), encoding="utf-8", newline="\n")
        print(f"wrote {path}")
        return 0
    if not path.exists() or json.loads(path.read_text(encoding="utf-8")) != fresh:
        print("test_vectors.json differs from the reference output (run with --write)", file=sys.stderr)
        return 1
    print("test_vectors.json matches the reference implementation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
