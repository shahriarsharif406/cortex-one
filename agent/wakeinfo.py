"""What can wake this computer? Read-only facts for ``doctor`` and ``power_capabilities``.

Sources (all read-only, fixed commands):
- ``powercfg /devicequery wake_armed``        devices allowed to wake the PC right now
- ``powercfg /devicequery wake_programmable`` devices that could be allowed to
- psutil network interfaces (names, IPv4 addresses, MAC addresses)

MAC addresses are for the LOCAL doctor output only. They never go into
``power_capabilities`` (which the phone and the AI can read).

Honesty: "armed" means Windows would accept a wake from that device. It does not
prove the router, Wi-Fi chip, BIOS or power state will cooperate. Wake works from
Sleep on many laptops; from Hibernate/Shutdown it usually needs a wired adapter
and BIOS support; a laptop with a dead battery and no mains cannot wake at all.
"""
from __future__ import annotations

import re
import subprocess
from typing import Any, Callable

Runner = Callable[[list[str], float], tuple[int, str]]

WIFI_WORDS = ("wireless", "wi-fi", "wifi", "802.11", "wlan")
LAN_WORDS = ("ethernet", "gigabit", "gbe", "fast ethernet", "lan", "realtek pcie", "family controller")
_NONE = {"none", "no devices", ""}


def default_runner(cmd: list[str], timeout: float = 15) -> tuple[int, str]:
    """Runs one of the fixed read-only commands below. Not a general shell."""
    if cmd[:2] != ["powercfg", "/devicequery"] or len(cmd) != 3 or cmd[2] not in (
            "wake_armed", "wake_programmable"):
        raise ValueError("only the two fixed powercfg queries may be run here")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return -1, ""
    return proc.returncode, (proc.stdout or "")[-8000:]


def parse_devicequery(text: str) -> list[str]:
    """Device names from powercfg output. 'NONE' (or empty) means no devices."""
    names = []
    for line in (text or "").splitlines():
        name = re.sub(r"[\x00-\x1f\x7f]", "", line).strip()
        if name.lower() in _NONE:
            continue
        names.append(name[:100])
    return names[:50]


def _has(names: list[str], words: tuple[str, ...]) -> bool:
    return any(any(w in n.lower() for w in words) for n in names)


def _tri(armed: list[str], programmable: list[str], words: tuple[str, ...], known: bool) -> str:
    if not known:
        return "unknown"
    if _has(armed, words):
        return "yes"
    if _has(programmable, words):
        return "no"      # could be enabled, but is not armed now
    return "no"


def wake_capabilities(runner: Runner | None = None) -> dict[str, Any]:
    """Parsed wake facts. ``known`` is False when powercfg could not be asked."""
    run = runner or default_runner
    try:
        c1, armed_text = run(["powercfg", "/devicequery", "wake_armed"], 15)
        c2, prog_text = run(["powercfg", "/devicequery", "wake_programmable"], 15)
    except Exception:
        c1, c2, armed_text, prog_text = -1, -1, "", ""
    known = c1 == 0 and c2 == 0
    armed = parse_devicequery(armed_text) if c1 == 0 else []
    programmable = parse_devicequery(prog_text) if c2 == 0 else []
    wifi = _tri(armed, programmable, WIFI_WORDS, known)
    lan = _tri(armed, programmable, LAN_WORDS, known)
    return {"known": known, "armed": armed, "programmable": programmable,
            "wifi_wake_from_sleep": wifi, "ethernet_wake": lan,
            "summary": summary_text(wifi, lan, known)}


def summary_text(wifi: str, lan: str, known: bool) -> str:
    if not known:
        return ("Wake capability is unknown: Windows could not be asked (needs Windows and "
                "powercfg). Test it yourself with a real sleep/wake from the other computer.")
    parts = [f"can wake from Sleep via Wi-Fi magic packet: {wifi}",
             f"can wake via a wired (Ethernet) magic packet: {lan}"]
    return ("; ".join(parts) + ". 'yes' only means Windows allows it: the router, BIOS and "
            "power state must also cooperate. Wake from Hibernate or Shutdown usually needs "
            "a wired adapter and BIOS support. A dead battery with no mains cannot wake.")


def adapters() -> list[dict[str, Any]]:
    """Interface name, IPv4 and MAC (local use only)."""
    out: list[dict[str, Any]] = []
    try:
        import psutil

        for name, addrs in psutil.net_if_addrs().items():
            ipv4 = [a.address for a in addrs if getattr(a.family, "name", "") == "AF_INET"]
            mac = next((a.address for a in addrs
                        if getattr(a.family, "name", "") in ("AF_LINK", "AF_PACKET")), "")
            out.append({"name": name[:60], "ipv4": ipv4, "mac": mac})
    except Exception:
        pass
    return out


def tailscale_present(adapter_list: list[dict[str, Any]]) -> bool:
    from .netbind import classify_address

    return any(classify_address(ip) == "tailscale" for a in adapter_list for ip in a["ipv4"])
