"""Per-adapter wake report, doctor verdicts and wake-setup (recorded sample outputs, no real calls)."""
import json

import pytest

from agent import wakeinfo
from agent.config import Settings
from agent.doctor import OK, WARN, run_checks
from agent.main import cmd_wake_setup

# Shape of powercfg output on the owner's laptop: two adapters + HID devices in the armed list.
ARMED = """Intel(R) Dual Band Wireless-N 7260
Intel(R) Ethernet Connection I218-LM
HID-compliant mouse
HID Keyboard Device
"""
PROGRAMMABLE = ARMED + "Standard PS/2 Keyboard\n"
CSV = ('"Name","InterfaceDescription","Status","MacAddress"\r\n'
       '"Wi-Fi","Intel(R) Dual Band Wireless-N 7260","Up","AA-BB-CC-00-11-22"\r\n'
       '"Ethernet","Intel(R) Ethernet Connection I218-LM","Disconnected","AA-BB-CC-33-44-55"\r\n'
       '"Bluetooth Network Connection","Bluetooth Device (Personal Area Network)","Disconnected","AA-BB-CC-66-77-88"\r\n')


def fake_powercfg(cmd, timeout):
    return 0, ARMED if cmd[2] == "wake_armed" else PROGRAMMABLE


def report():
    wake = wakeinfo.wake_capabilities(fake_powercfg)
    return wakeinfo.adapter_wake_report(wake, wakeinfo.parse_netadapter_csv(CSV))


def test_report_for_this_laptop():
    r = {x["kind"]: x for x in report()}
    assert set(r) == {"wifi", "ethernet"}               # bluetooth PAN and HID ignored
    assert r["wifi"]["armed"] == "yes" and r["wifi"]["connected"] == "yes"
    assert r["ethernet"]["armed"] == "yes" and r["ethernet"]["connected"] == "no"
    assert all("mac" not in x for x in r.values())


def test_verdicts_are_honest():
    lines = wakeinfo.verdict_lines(report())
    assert "Wi-Fi wake: armed (untested)" in lines
    assert any(l.startswith("Ethernet wake: armed but") and "not connected" in l for l in lines)


def test_not_armed_and_unknown():
    wake = {"known": True, "armed": [], "programmable": ["Intel(R) Dual Band Wireless-N 7260"]}
    r = wakeinfo.adapter_wake_report(wake, wakeinfo.parse_netadapter_csv(CSV))
    assert r[0]["armed"] == "no" and r[0]["programmable"] == "yes"
    assert "not armed" in wakeinfo.verdict_lines(r)[0]
    r = wakeinfo.adapter_wake_report({"known": False}, wakeinfo.parse_netadapter_csv(CSV))
    assert r[0]["armed"] == "unknown" and "unknown" in wakeinfo.verdict_lines(r)[0]


def test_csv_parser_tolerates_garbage():
    assert wakeinfo.parse_netadapter_csv("") == []
    assert wakeinfo.parse_netadapter_csv("\x00\x01 not,csv at all") == []
    rows = wakeinfo.parse_netadapter_csv(CSV.replace("Wi-Fi", "Wi\x1b[31m-Fi"))
    assert "\x1b" not in rows[0]["name"]


def test_doctor_shows_verdicts_and_hides_macs(tmp_path):
    s = Settings(data_dir=tmp_path)
    wake = wakeinfo.wake_capabilities(fake_powercfg)
    rows = wakeinfo.parse_netadapter_csv(CSV)
    adapters = [{"name": "Wi-Fi", "ipv4": ["192.168.1.9"], "mac": "AA-BB-CC-00-11-22"}]
    checks = run_checks(s, env={}, startup_probe=lambda: None, wake_probe=lambda: wake,
                        adapter_probe=lambda: adapters, netadapter_probe=lambda: rows)
    text = "\n".join(c.line() for c in checks)
    assert "Wi-Fi wake: armed (untested)" in text
    assert "Ethernet wake: armed but" in text
    assert "AA-BB-CC" not in text
    checks = run_checks(s, env={}, startup_probe=lambda: None, wake_probe=lambda: wake,
                        adapter_probe=lambda: adapters, netadapter_probe=lambda: rows, show_mac=True)
    assert "AA-BB-CC-00-11-22" in "\n".join(c.line() for c in checks)


def test_wake_setup_writes_macs_only_to_config(tmp_path, capsys):
    s = Settings(data_dir=tmp_path)
    rows = wakeinfo.parse_netadapter_csv(CSV)
    assert cmd_wake_setup(s, None, ask=lambda _p: "Laptop", rows_fn=lambda: rows) == 0
    out = capsys.readouterr().out
    assert "AA-BB-CC" not in out and "aa:bb:cc" not in out.lower()
    saved = json.loads((tmp_path / "config.json").read_text(encoding="utf-8"))
    assert saved["wake_targets"]["laptop-wifi"]["mac"] == "aa:bb:cc:00:11:22"
    assert saved["wake_targets"]["laptop-ethernet"]["broadcast"] == "255.255.255.255"
    from agent.actions import wake_target
    assert wake_target(Settings.load(tmp_path), "laptop-wifi")[0].hex() == "aabbcc001122"


@pytest.mark.parametrize("name", ["", "a b", "../x", "x" * 40, "ü"])
def test_wake_setup_rejects_bad_names(tmp_path, name):
    s = Settings(data_dir=tmp_path)
    assert cmd_wake_setup(s, None, ask=lambda _p: name,
                          rows_fn=lambda: wakeinfo.parse_netadapter_csv(CSV)) == 1
    assert not (tmp_path / "config.json").exists()


def test_wake_setup_without_adapters(tmp_path):
    assert cmd_wake_setup(Settings(data_dir=tmp_path), None, ask=lambda _p: "x", rows_fn=lambda: []) == 1
