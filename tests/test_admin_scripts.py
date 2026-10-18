"""Admin scripts are never run for real here. We parse them and prove that every command that
changes the system sits inside a ShouldProcess guard (so -WhatIf really changes nothing)."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
ADMIN = ["setup-network-priority.ps1", "set-power-plan.ps1", "network-failover.ps1",
         "install-network-failover.ps1"]
CHANGING = re.compile(r"\b(Set-NetIPInterface|Disable-NetAdapter|Enable-NetAdapter|"
                      r"Register-ScheduledTask|Unregister-ScheduledTask|Copy-Item|"
                      r"icacls\.exe|powercfg\.exe)\b")


def guarded_lines(text: str) -> set[int]:
    """Line numbers that sit inside a block opened by a line with ShouldProcess(."""
    lines = text.splitlines()
    inside: set[int] = set()
    for i, line in enumerate(lines):
        if "ShouldProcess(" in line and line.rstrip().endswith("{"):
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                inside.add(j)
                if depth <= 0:
                    break
    return inside


@pytest.mark.parametrize("name", ADMIN)
def test_every_changing_command_is_inside_shouldprocess(name):
    text = (SCRIPTS / name).read_text(encoding="utf-8")
    assert "SupportsShouldProcess = $true" in text
    inside = guarded_lines(text)
    for i, line in enumerate(text.splitlines()):
        code = line.split("#")[0]
        if CHANGING.search(code) and not code.lstrip().startswith(("<#", "*", ".", "Write-Host")):
            assert i in inside, f"{name}:{i + 1} changes the system outside ShouldProcess: {line.strip()}"


@pytest.mark.parametrize("name", [n for n in ADMIN if n != "network-failover.ps1"])  # runs as SYSTEM
def test_requires_admin_unless_whatif(name):
    text = (SCRIPTS / name).read_text(encoding="utf-8")
    assert "Test-Admin" in text and "$WhatIfPreference" in text


def test_failover_has_no_network_derived_values():
    text = (SCRIPTS / "network-failover.ps1").read_text(encoding="utf-8")
    assert "Invoke-WebRequest" not in text and "Invoke-Expression" not in text
    assert "iex " not in text.lower()
    assert "ValidatePattern" in text                       # adapter names are pattern-checked
    # it must only re-enable an adapter that it disabled itself
    assert "$state.disabledAt" in text


def test_installer_locks_the_script_folder_for_users():
    text = (SCRIPTS / "install-network-failover.ps1").read_text(encoding="utf-8")
    assert "/inheritance:r" in text and "S-1-5-32-545:(OI)(CI)RX" in text   # Users: read only
    assert "SYSTEM" in text


def test_power_plan_values():
    text = (SCRIPTS / "set-power-plan.ps1").read_text(encoding="utf-8")
    assert "'LIDACTION', '0'" in text and "BATACTIONCRIT', '2'" in text
    assert "standby-timeout-ac" in text and "monitor-timeout-ac" in text
    assert "PBUTTONACTION" in text


def test_network_priority_metrics_default():
    text = (SCRIPTS / "setup-network-priority.ps1").read_text(encoding="utf-8")
    assert "$WifiMetric = 10" in text and "$TetherMetric = 50" in text


@pytest.mark.skipif(shutil.which("powershell") is None, reason="needs PowerShell")
@pytest.mark.parametrize("name", ADMIN)
def test_scripts_parse(name):
    cmd = ("$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("
           f"'{SCRIPTS / name}',[ref]$null,[ref]$e); if ($e.Count) {{ $e | % {{ $_.Message }}; exit 1 }}")
    proc = subprocess.run(["powershell", "-NoProfile", "-Command", cmd],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_wake_test_prep_is_read_only_and_prints_no_mac():
    text = (SCRIPTS / "wake-test-prep.ps1").read_text(encoding="utf-8")
    code = "\n".join(l for l in text.splitlines() if not l.strip().startswith(("#", "<#", "Say ")))
    for bad in ("Set-", "Disable-", "Enable-", "New-", "Remove-", "netsh", "reg add", "reg delete",
                "powercfg /h", "deviceenablewake", "devicedisablewake", "shutdown", "Restart-", "Stop-Computer"):
        assert bad.lower() not in code.lower(), bad
    assert "MacAddress" not in code
    assert "-WhatIf" not in code


@pytest.mark.skipif(shutil.which("powershell") is None, reason="needs PowerShell")
def test_wake_test_prep_parses():
    cmd = ("$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("
           f"'{SCRIPTS / 'wake-test-prep.ps1'}',[ref]$null,[ref]$e); if ($e.Count) {{ exit 1 }}")
    assert subprocess.run(["powershell", "-NoProfile", "-Command", cmd], timeout=60).returncode == 0


def test_verify_release_flags_secrets_and_real_macs(tmp_path):
    import importlib.util
    import zipfile

    spec = importlib.util.spec_from_file_location("verify_release", SCRIPTS / "verify_release.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    clean = tmp_path / "clean.zip"
    with zipfile.ZipFile(clean, "w") as z:
        z.writestr("p/README.md", "fake mac AA:BB:CC:DD:EE:FF and 11-22-33-44-55-66")
    assert mod.problems(str(clean)) == []
    for name, body in [("p/config.json", "{}"), ("p/.env", "x"), ("p/firmware/include/secrets.h", "x"),
                       ("p/notes.txt", "wifi 3C:97:0E:12:34:56 here"), ("p/a.db", "x")]:
        bad = tmp_path / "bad.zip"
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr(name, body)
        assert mod.problems(str(bad)), name
