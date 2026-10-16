"""Secret scan used by the pre-commit hook and by scripts/check.ps1.

    python scripts/precommit_check.py --staged   # what `git commit` is about to record
    python scripts/precommit_check.py --all      # every tracked file (release check)

Blocks: Anthropic keys (`sk-ant-`), files that must never be committed (.env,
config.json, key.properties, keystores, private keys) and assignments of 32+
character random-looking values (tokens, secrets, passwords...). A line that is
a known false positive can carry the comment text ``secret-scan:allow``.
Prints file and line number only, never the matched value. Stdlib only.
"""
from __future__ import annotations

import fnmatch
import math
import os
import re
import subprocess
import sys

BLOCKED_NAMES = (".env", ".env.*", "config.json", "key.properties", "*.jks", "*.keystore",
                 "*.p12", "*.pfx", "*.pem", "*.key", "id_rsa", "id_ed25519")
ALLOWED_NAMES = (".env.example", "key.properties.example", "config.example.json")
SKIP_CONTENT = ("*.lock", "package-lock.json", "*.png", "*.jpg", "*.jpeg", "*.ico", "*.webp",
                "*.zip", "*.jar", "*.db", "*.ttf", "*.otf", "*.keystore.example", ".metadata")
ANTHROPIC = re.compile(r"sk-ant-")
REALISTIC_ANTHROPIC = re.compile(r"sk-ant-[A-Za-z0-9_-]{30,}")
# name = "value" / name: value / NAME=value, value of 32+ token characters
ASSIGN = re.compile(r"""(?ix)
    (?P<name>[A-Za-z_][\w.-]*)\s*(?:=|:)\s*(?P<q>["']?)(?P<value>[A-Za-z0-9_+/=~-]{32,})(?P=q)(?![\w+/=~-])""")
ALLOW_MARK = "secret-scan:allow"
TEST_DIRS = ("tests/",)


def entropy(text: str) -> float:
    counts = {c: text.count(c) for c in set(text)}
    return -sum(n / len(text) * math.log2(n / len(text)) for n in counts.values())


def blocked_file(path: str) -> bool:
    base = os.path.basename(path).lower()
    if any(fnmatch.fnmatch(base, a) for a in ALLOWED_NAMES):
        return False
    return any(fnmatch.fnmatch(base, b) for b in BLOCKED_NAMES)


def looks_random(value: str) -> bool:
    if value.isdigit() or len(set(value)) < 8:
        return False
    has_alpha, has_digit = any(c.isalpha() for c in value), any(c.isdigit() for c in value)
    return has_alpha and has_digit and entropy(value) >= 3.5


def scan_line(path: str, line: str) -> str | None:
    """Reason this line is not allowed, or None."""
    if ALLOW_MARK in line:
        return None
    in_tests = path.replace("\\", "/").startswith(TEST_DIRS)
    if ANTHROPIC.search(line):
        # tests need fake keys like "sk-ant-test-not-real"; a realistic one is still a leak
        if not in_tests or REALISTIC_ANTHROPIC.search(line):
            return "Anthropic API key pattern (sk-ant-)"
    if in_tests:
        return None            # test fixtures hold long fake ids on purpose
    for m in ASSIGN.finditer(line):
        value = m.group("value")
        if "/" in value and value.count("/") > 2:
            continue           # looks like a path / URL, not a token
        if looks_random(value):
            return f"long random-looking value assigned to '{m.group('name')[:30]}'"
    return None


def scan_text(path: str, text: str) -> list[tuple[int, str]]:
    return [(i, why) for i, line in enumerate(text.splitlines(), 1)
            if (why := scan_line(path, line))]


def git(*args: str) -> str:
    return subprocess.run(["git", "-c", "core.quotepath=off", *args], capture_output=True,
                          text=True, encoding="utf-8", errors="replace", check=True).stdout


def staged_findings() -> list[str]:
    out: list[str] = []
    files = [f for f in git("diff", "--cached", "--name-only", "--diff-filter=ACMR").splitlines() if f]
    for f in files:
        if blocked_file(f):
            out.append(f"{f}: this kind of file must never be committed")
    current, lineno = "", 0
    for raw in git("diff", "--cached", "-U0", "--no-color", "--no-ext-diff").splitlines():
        if raw.startswith("+++ "):
            current = raw[6:] if raw.startswith("+++ b/") else ""
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            lineno = int(m.group(1)) if m else 0
        elif raw.startswith("+") and current and not any(
                fnmatch.fnmatch(os.path.basename(current).lower(), s) for s in SKIP_CONTENT):
            why = scan_line(current, raw[1:])
            if why:
                out.append(f"{current}:{lineno}: {why}")
            lineno += 1
    return out


def all_findings() -> list[str]:
    out: list[str] = []
    for f in git("ls-files").splitlines():
        if blocked_file(f):
            out.append(f"{f}: this kind of file must never be committed")
            continue
        if any(fnmatch.fnmatch(os.path.basename(f).lower(), s) for s in SKIP_CONTENT):
            continue
        try:
            with open(f, "rb") as fh:
                data = fh.read(2_000_000)
        except OSError:
            continue
        if b"\x00" in data:
            continue
        for n, why in scan_text(f, data.decode("utf-8", "replace")):
            out.append(f"{f}:{n}: {why}")
    return out


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else "--staged"
    if mode not in ("--staged", "--all"):
        print("usage: precommit_check.py --staged | --all", file=sys.stderr)
        return 2
    found = staged_findings() if mode == "--staged" else all_findings()
    if not found:
        return 0
    print("Secret scan: blocked.", file=sys.stderr)
    for item in found[:50]:
        print("  " + item, file=sys.stderr)
    print("Remove the secret (use an environment variable), or add 'secret-scan:allow' to a "
          "line that is a false positive.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
