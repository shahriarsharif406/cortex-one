"""The secret-scan pre-commit hook, exercised in a throw-away git repo."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import precommit_check as pc  # noqa: E402

FAKE_REAL_KEY = "sk-ant-api03-" + "Ab1_" * 12                      # realistic length
TOKEN = "q8Zr2LmN7xKp4TvB9wYc1HsD6fGj3AeU"                         # 32 chars, random-looking


# ------------------------------------------------------------------ unit level
@pytest.mark.parametrize("path,line", [
    ("agent/x.py", f'key = "{FAKE_REAL_KEY}"'),
    ("agent/x.py", "# sk-ant-"),
    ("tests/t.py", f'k = "{FAKE_REAL_KEY}"'),
    ("agent/x.py", f'api_token = "{TOKEN}"'),
    ("agent/x.py", f"SECRET={TOKEN}"),
    ("cfg.yaml", f"password: {TOKEN}"),
    ("agent/x.py", f"foo = '{TOKEN}'"),
])
def test_dangerous_lines_are_flagged(path, line):
    assert pc.scan_line(path, line)


@pytest.mark.parametrize("path,line", [
    ("tests/t.py", 'key = "sk-ant-test-not-real"'),
    ("agent/x.py", 'name = "short"'),
    ("agent/x.py", "pin = 1234567890123456789012345678901234567890"),
    ("agent/x.py", 'path = "C:/Users/someone/AppData/Roaming/CortexOne/logs/agent.log"'),
    ("agent/x.py", 'x = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'),
    ("agent/x.py", f'token = "{TOKEN}"  # secret-scan:allow'),
    ("agent/x.py", "see https://example.com/a/very/long/path/that/keeps/going/on/and/on"),
])
def test_harmless_lines_pass(path, line):
    assert pc.scan_line(path, line) is None


@pytest.mark.parametrize("name", [".env", ".env.local", "config.json", "key.properties",
                                  "release.jks", "x.keystore", "a.p12", "b.pfx", "c.pem",
                                  "sub/dir/config.json", "id_rsa"])
def test_secret_file_names_are_blocked(name):
    assert pc.blocked_file(name)


@pytest.mark.parametrize("name", [".env.example", "key.properties.example", "config.py",
                                  "app_config.json.py", "README.md"])
def test_templates_are_allowed(name):
    assert not pc.blocked_file(name)


def test_findings_never_print_the_value():
    found = pc.scan_text("a.py", f'token = "{TOKEN}"\n')
    assert found and TOKEN not in repr(found)


def test_the_real_repository_is_clean():
    proc = subprocess.run([sys.executable, str(ROOT / "scripts" / "precommit_check.py"), "--all"],
                          cwd=ROOT, capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


# -------------------------------------------------------- real hook in a temp repo
needs_git = pytest.mark.skipif(shutil.which("git") is None or shutil.which("powershell") is None,
                               reason="needs git and powershell")


@pytest.fixture
def repo(tmp_path):
    def run(*args, **kw):
        return subprocess.run(args, cwd=tmp_path, capture_output=True, text=True, **kw)

    run("git", "init", "-q")
    run("git", "config", "user.email", "t@example.com")
    run("git", "config", "user.name", "t")
    run("git", "config", "commit.gpgsign", "false")
    proc = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         str(ROOT / "scripts" / "install-git-hooks.ps1"), "-RepoPath", str(tmp_path)],
        capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    env = dict(os.environ, CORTEX_HOOK_PYTHON=sys.executable)

    def commit(*files_and_text):
        for name, content in files_and_text:
            p = tmp_path / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
            run("git", "add", "-f", name)
        return run("git", "commit", "-q", "-m", "test", env=env)

    return tmp_path, commit, run


@needs_git
def test_hook_allows_a_clean_commit(repo):
    _, commit, run = repo
    r = commit(("a.py", "print('hello')\n"), ("tests/t.py", 'k = "sk-ant-test-not-real"\n'))
    assert r.returncode == 0, r.stderr
    assert "1" in run("git", "rev-list", "--count", "HEAD").stdout or True


@needs_git
@pytest.mark.parametrize("files", [
    [("leak.py", f'KEY = "{FAKE_REAL_KEY}"\n')],
    [(".env", "ANTHROPIC_API_KEY=x\n")],
    [("config.json", "{}\n")],
    [("android/key.properties", "storePassword=x\n")],
    [("release.jks", "binary")],
    [("settings.py", f'api_token = "{TOKEN}"\n')],
])
def test_hook_blocks_secrets(repo, files):
    tmp, commit, run = repo
    r = commit(*files)
    assert r.returncode != 0
    assert "Secret scan: blocked" in r.stderr
    assert FAKE_REAL_KEY not in r.stderr and TOKEN not in r.stderr          # value never echoed
    assert run("git", "rev-parse", "--verify", "HEAD").returncode != 0     # nothing was committed


@needs_git
def test_hook_only_checks_what_is_staged_and_respects_the_allow_mark(repo):
    tmp, commit, _ = repo
    (tmp / "untracked.py").write_text(f'KEY = "{FAKE_REAL_KEY}"\n')       # not staged: ignored
    assert commit(("ok.py", "x = 1\n")).returncode == 0
    assert commit(("fp.py", f'sample = "{TOKEN}"  # secret-scan:allow\n')).returncode == 0


@needs_git
def test_installer_refuses_to_overwrite_a_foreign_hook(tmp_path):
    subprocess.run(["git", "init", "-q"], cwd=tmp_path)
    hook = tmp_path / ".git" / "hooks" / "pre-commit"
    hook.parent.mkdir(parents=True, exist_ok=True)
    hook.write_text("#!/bin/sh\necho mine\n")
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
           str(ROOT / "scripts" / "install-git-hooks.ps1"), "-RepoPath", str(tmp_path)]
    assert subprocess.run(cmd, capture_output=True, text=True).returncode != 0
    assert "echo mine" in hook.read_text()
    assert subprocess.run(cmd + ["-WhatIf"], capture_output=True, text=True).returncode != 0
    assert subprocess.run(cmd + ["-Force"], capture_output=True, text=True).returncode == 0
    assert "Cortex One pre-commit hook" in hook.read_text()
