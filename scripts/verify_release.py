"""Checks a release zip: no config/secret/database files and no real-looking MAC addresses.

usage: python scripts/verify_release.py <zip>        exit 0 = clean, 1 = problems
Fake MACs used in tests/docs (AA:BB:CC..., 11:22:33..., 00:00..., FF:FF...) are allowed.
"""
from __future__ import annotations

import re
import sys
import zipfile

FORBIDDEN_NAMES = re.compile(
    r"(^|/)(config\.json|\.env(\..*)?|secrets\.h|key\.properties|[^/]*\.(db|jks|keystore|pem|key|p12|pfx)|"
    r"PROGRESS\.md|FINAL_REPORT\.md|SESSION_PROMPT[^/]*\.md|\.claude/.*)$")
MAC = re.compile(r"(?<![0-9A-Fa-f:-])([0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5})(?![0-9A-Fa-f:-])")
FAKE_PREFIXES = ("AA:BB:CC", "11:22:33", "00:00:00", "FF:FF:FF", "01:02:03", "DE:AD:BE", "12:34:56",
                 "00:11:22", "A1:B2:C3")


def problems(path: str) -> list[str]:
    out: list[str] = []
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if FORBIDDEN_NAMES.search(name):
                out.append(f"forbidden file: {name}")
                continue
            if name.endswith("/") or z.getinfo(name).file_size > 2_000_000:
                continue
            try:
                text = z.read(name).decode("utf-8")
            except UnicodeDecodeError:
                continue
            for m in MAC.finditer(text):
                mac = m.group(1).upper().replace("-", ":")
                if not mac.startswith(FAKE_PREFIXES):
                    out.append(f"real-looking MAC in {name}")
                    break
    return out


if __name__ == "__main__":
    found = problems(sys.argv[1])
    for p in found:
        print("PROBLEM:", p)
    print("release zip is clean" if not found else f"{len(found)} problem(s)")
    raise SystemExit(1 if found else 0)
