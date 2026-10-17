"""Session 2, phase 1: bind addresses, retry, health, network watchdog, data-saver."""
import io
import threading
import time

import pytest
from fastapi.testclient import TestClient

from agent import screenshots, wakeinfo
from agent.doctor import FAIL, OK, run_checks
from agent.netbind import BindError, BindManager, check_bind_address, effective_hosts
from agent.netwatch import NetWatcher, parse_targets
from agent.server import create_app
from agent.wakeinfo import default_runner as REAL_RUNNER   # imported before conftest patches it


# ---------------------------------------------------------------- addresses
@pytest.mark.parametrize("addr", ["127.0.0.1", "127.5.5.5", "100.64.0.1", "100.101.102.103",
                                  "100.127.255.254", "10.1.2.3", "172.16.0.9", "172.31.1.1",
                                  "192.168.1.20", "localhost"])
def test_allowed_addresses(addr):
    assert check_bind_address(addr)


@pytest.mark.parametrize("addr", ["0.0.0.0", "::", "", " ", "8.8.8.8", "100.63.255.255",
                                  "100.128.0.1", "172.32.0.1", "192.169.0.1", "11.0.0.1",
                                  "example.com", "::1", "[::]", "1.2.3",
                                  "100.64.0.1/10", "0", "٣.٣.٣.٣", None, 5,
                                  ["127.0.0.1"]])
def test_rejected_addresses(addr):
    with pytest.raises(BindError):
        check_bind_address(addr)


def test_surrounding_space_is_trimmed():
    assert check_bind_address("127.0.0.1 ") == "127.0.0.1"


def test_error_message_is_clear():
    with pytest.raises(BindError, match="0.0.0.0"):
        check_bind_address("0.0.0.0")


def test_effective_hosts_old_single_host_still_works(settings):
    settings.hosts = []
    settings.host = "127.0.0.1"
    assert effective_hosts(settings) == ["127.0.0.1"]
    settings.host = "0.0.0.0"
    with pytest.raises(BindError):
        effective_hosts(settings)


def test_effective_hosts_list_wins_and_dedups(settings):
    settings.hosts = ["100.101.102.103", "192.168.1.5", "100.101.102.103"]
    assert effective_hosts(settings) == ["100.101.102.103", "192.168.1.5"]


def test_one_bad_host_rejects_the_whole_list(settings):
    settings.hosts = ["127.0.0.1", "8.8.8.8"]
    with pytest.raises(BindError):
        effective_hosts(settings)
    settings.hosts = "127.0.0.1"
    with pytest.raises(BindError):
        effective_hosts(settings)
    settings.hosts = ["127.0.0.1"] * 9 + ["127.0.0.2"]
    with pytest.raises(BindError):
        effective_hosts(settings)


def test_bind_manager_refuses_bad_address():
    with pytest.raises(BindError):
        BindManager(["0.0.0.0"], 1, lambda h, p: None)


def test_serve_refuses_wildcard(settings, capsys):
    from agent.main import cmd_serve

    settings.host = "0.0.0.0"
    assert cmd_serve(settings, None) == 2
    assert "Refusing to start" in capsys.readouterr().err


# ------------------------------------------------------------- bind manager
class FakeServer:
    def __init__(self, host, port, log):
        self.host, self.port, self.log = host, port, log
        self.stopped = threading.Event()

    def serve(self):
        self.log.append(("start", self.host, self.port))
        self.stopped.wait(30)

    def request_stop(self):
        self.stopped.set()


def wait_for(cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return False


def test_address_not_up_is_retried_then_bound_when_it_appears():
    log, ifaces = [], set()
    m = BindManager(["100.101.102.103"], 8765, lambda h, p: FakeServer(h, p, log),
                    interfaces=lambda: set(ifaces), base_delay=0.02, max_delay=0.1, poll=0.02)
    m.start()
    try:
        assert wait_for(lambda: m.status["100.101.102.103"] == "waiting")
        time.sleep(0.15)
        assert log == []                          # not bound while the address is missing
        ifaces.add("100.101.102.103")
        assert wait_for(lambda: log == [("start", "100.101.102.103", 8765)])
        assert m.status["100.101.102.103"] == "up"
    finally:
        m.stop()


def test_never_falls_back_to_another_address():
    log = []
    m = BindManager(["100.101.102.103"], 8765, lambda h, p: FakeServer(h, p, log),
                    interfaces=lambda: {"192.168.1.5"}, base_delay=0.01, max_delay=0.02, poll=0.01)
    m.start()
    time.sleep(0.2)
    m.stop()
    assert log == []


def test_address_that_disappears_is_unbound_and_rebound():
    log, ifaces = [], {"100.101.102.103"}
    servers = []

    def make(h, p):
        s = FakeServer(h, p, log)
        servers.append(s)
        return s

    m = BindManager(["100.101.102.103"], 1, make, interfaces=lambda: set(ifaces),
                    base_delay=0.02, max_delay=0.05, poll=0.01)
    m.start()
    try:
        assert wait_for(lambda: len(servers) == 1)
        ifaces.clear()
        assert wait_for(lambda: servers[0].stopped.is_set())
        ifaces.add("100.101.102.103")
        assert wait_for(lambda: len(servers) == 2)
    finally:
        m.stop()


def test_backoff_doubles_up_to_the_cap():
    waits = []

    class Recorder(threading.Event):
        def wait(self, timeout=None):
            waits.append(timeout)
            return len(waits) >= 8

    m = BindManager(["100.101.102.103"], 1, lambda h, p: None, interfaces=lambda: set(),
                    base_delay=1, max_delay=10)
    m._stop = Recorder()
    m._run_host("100.101.102.103")
    assert waits[:6] == [1, 2, 4, 8, 10, 10]


def test_default_backoff_cap_is_ten_minutes():
    from agent.netbind import MAX_BACKOFF

    assert MAX_BACKOFF == 600


def test_each_listed_address_gets_its_own_server():
    log = []
    m = BindManager(["127.0.0.1", "127.0.0.2"], 9, lambda h, p: FakeServer(h, p, log),
                    base_delay=0.01, poll=0.01)
    m.start()
    try:
        assert wait_for(lambda: len(log) == 2)
        assert {x[1] for x in log} == {"127.0.0.1", "127.0.0.2"}
    finally:
        m.stop()


def test_server_crash_on_bind_error_is_survived():
    attempts = []

    class Crashy:
        def serve(self):
            attempts.append(1)
            raise SystemExit(1)           # what uvicorn does when the port is busy

        def request_stop(self):
            pass

    m = BindManager(["127.0.0.1"], 1, lambda h, p: Crashy(), base_delay=0.02, max_delay=0.05,
                    poll=0.01)
    m.start()
    try:
        assert wait_for(lambda: len(attempts) >= 2)
    finally:
        m.stop()


# ------------------------------------------------------------------- health
@pytest.fixture
def client(engine, settings):
    return TestClient(create_app(settings, engine))


def test_health_fields_and_no_secrets(client, engine, settings):
    settings.computer_name = "Laptop-One"
    body = client.get("/health").json()
    assert body["computer_name"] == "Laptop-One"
    assert len(body["computer_id"]) == 16
    assert client.get("/health").json()["computer_id"] == body["computer_id"]  # stable
    assert body["uptime_seconds"] >= 0 and body["battery"] is None
    text = str(body).lower()
    for bad in ("token", "hash", "secret", "mac", str(settings.data_dir).lower()):
        assert bad not in text


def test_health_reports_battery(client, engine):
    from agent.power import Battery

    engine.battery_provider = lambda: Battery(61.4, False)
    assert client.get("/health").json()["battery"] == {"percent": 61, "plugged": False}


def test_health_link_only_names_configured_addresses(engine, settings):
    settings.hosts = ["127.0.0.1"]
    assert engine.health("203.0.113.9")["link"] is None          # not one of ours
    assert engine.health("127.0.0.1")["link"] == {"address": "127.0.0.1", "kind": "loopback"}
    settings.hosts = ["127.0.0.1", "100.101.102.103"]
    assert engine.health("100.101.102.103")["link"]["kind"] == "tailscale"


# ----------------------------------------------------------------- watchdog
def test_targets_parse_and_reject_bad():
    ok, problems = parse_targets(None)
    assert ("api.anthropic.com", 443) in ok and not problems
    ok, problems = parse_targets(["a.example:80", "ok.example:443", "bad", "x:0", "x:99999",
                                  "-a-.b:1"])
    assert ok == [("a.example", 80), ("ok.example", 443)] and len(problems) == 4
    ok, problems = parse_targets(["h/x:1", 5, "a.example:80"] + ["b.example:1"] * 6)
    assert len(ok) == 4 and any("first" in p for p in problems)     # only 6 entries are read
    ok, problems = parse_targets("api.anthropic.com:443")
    assert ok == [] and problems


def test_watchdog_states_and_debounce(engine):
    w = NetWatcher(engine, probe=lambda h, p: True)
    assert w.tick() == "ok" and w.state == "ok"       # first reading, nothing alerted
    assert engine.alerts.recent(10, scope="net") == []
    w.probe = lambda h, p: False
    assert w.tick() is None and w.state == "ok"       # one bad reading is not enough
    assert w.tick() == "offline" and w.state == "offline"
    w.probe = lambda h, p: h == "api.anthropic.com"
    assert w.tick() is None
    assert w.tick() == "degraded"
    w.probe = lambda h, p: True
    w.tick()
    assert w.tick() == "ok"
    kinds = [a["kind"] for a in engine.alerts.recent(10, scope="net")]
    assert kinds == ["net_ok", "net_degraded", "net_offline"]
    # net alerts never leak into the power alerts feed
    assert engine.alerts.recent(10, scope="power") == []


def test_watchdog_flapping_does_not_alert(engine):
    w = NetWatcher(engine, probe=lambda h, p: True)
    w.tick()
    for good in (False, True, False, True):
        w.probe = (lambda g: lambda h, p: g)(good)
        w.tick()
    assert engine.alerts.recent(10, scope="net") == []


def test_watchdog_never_raises_and_never_touches_adapters(engine, runner):
    def boom(h, p):
        raise RuntimeError("x")

    w = NetWatcher(engine, probe=boom)
    w.tick()
    w.tick()
    assert w.state in ("offline", "unknown")
    assert runner.calls == []                          # report only


def test_watchdog_notifies_without_target_details(engine):
    sent = []

    class N:
        def notify(self, event, pct, when):
            sent.append((event, pct))

    w = NetWatcher(engine, probe=lambda h, p: True, notifier=N())
    w.tick()
    w.probe = lambda h, p: False
    w.tick()
    w.tick()
    assert sent == [("Internet is unreachable from this computer", None)]


def test_health_shows_network_state(client, engine):
    engine.net.state, engine.net.since = "offline", 123.0
    assert client.get("/health").json()["network"] == {"state": "offline", "since": 123.0}


def test_network_endpoint_needs_a_token(client):
    assert client.get("/network").status_code == 401


# --------------------------------------------------------------- data saver
def png_bytes():
    from PIL import Image

    im = Image.new("RGB", (1600, 900))
    for x in range(0, 1600, 7):
        for y in range(0, 900, 11):
            im.putpixel((x, y), ((x * 3) % 256, (y * 5) % 256, (x + y) % 256))
    out = io.BytesIO()
    im.save(out, "PNG")
    return out.getvalue()


NAME = "screenshot-20260101-000000.png"


def test_quality_low_is_smaller_jpeg(engine, settings):
    settings.screenshots_dir.mkdir(parents=True, exist_ok=True)
    (settings.screenshots_dir / NAME).write_bytes(png_bytes())
    normal, mime_n = screenshots.load_screenshot(settings, NAME, None, "normal")
    low, mime_l = screenshots.load_screenshot(settings, NAME, None, "low")
    assert mime_l == "image/jpeg" and low.startswith(b"\xff\xd8") and len(low) < len(normal) / 3
    assert mime_n == "image/png"


def test_quality_param_over_http(client, engine, settings):
    code = engine.pairing.create_code()
    tok = client.post("/pair", json={"code": code}).json()["token"]
    h = {"Authorization": f"Bearer {tok}"}
    settings.screenshots_dir.mkdir(parents=True, exist_ok=True)
    (settings.screenshots_dir / NAME).write_bytes(png_bytes())
    low = client.get(f"/screenshots/{NAME}?quality=low", headers=h)
    assert low.status_code == 200 and low.headers["content-type"] == "image/jpeg"
    assert client.get(f"/screenshots/{NAME}?quality=ultra", headers=h).status_code == 400
    assert client.get(f"/screenshots/{NAME}", headers=h).status_code == 200


def test_take_screenshot_low_saves_a_jpeg(engine, settings):
    engine.ctx.screenshotter = lambda p: p.write_bytes(png_bytes())
    r = engine.run("take_screenshot", {"quality": "low"}, "t", "cli")
    assert r.ok and r.data["file"].endswith(".jpg")
    assert not list(settings.screenshots_dir.glob("*.png"))
    r2 = engine.run("take_screenshot", {}, "t", "cli")
    assert r2.ok and r2.data["file"].endswith(".png")


def test_take_screenshot_bad_quality(engine):
    r = engine.run("take_screenshot", {"quality": "ultra"}, "t", "cli")
    assert not r.ok and "low" in r.message


# ------------------------------------------------------------------- doctor
def test_doctor_reports_bad_hosts_and_good_hosts(settings):
    settings.hosts = ["0.0.0.0"]
    checks = run_checks(settings, env={}, startup_probe=lambda: None)
    assert any(c.level == FAIL and "0.0.0.0" in c.en for c in checks)
    settings.hosts = ["127.0.0.1"]
    checks = run_checks(settings, env={}, startup_probe=lambda: None)
    assert any(c.level == OK and "bind address" in c.en for c in checks)


def test_doctor_wake_and_adapters(settings):
    def fake(cmd, t):
        if cmd[2] == "wake_armed":
            return 0, "Intel(R) Wireless-AC 7265\n"
        return 0, "Intel(R) Wireless-AC 7265\nRealtek PCIe GbE Family Controller\n"

    caps = wakeinfo.wake_capabilities(fake)
    assert caps["wifi_wake_from_sleep"] == "yes" and caps["ethernet_wake"] == "no"
    adapters = [{"name": "Wi-Fi", "ipv4": ["192.168.1.9"], "mac": "AA-BB-CC-DD-EE-FF"},
                {"name": "Tailscale", "ipv4": ["100.101.102.103"], "mac": ""}]
    settings.backup_adapter_name = "Ethernet 2"
    checks = run_checks(settings, env={}, startup_probe=lambda: None,
                        wake_probe=lambda: caps, adapter_probe=lambda: adapters)
    text = "\n".join(c.line() for c in checks)
    assert "Tailscale address is present" in text
    assert "backup interface is not present" in text
    assert "wake via Wi-Fi: yes" in text
    assert "AA-BB-CC-DD-EE-FF" in text            # MACs only in the local doctor report


def test_wake_parse_none_and_unknown():
    assert wakeinfo.parse_devicequery("NONE\n") == []
    assert wakeinfo.parse_devicequery("A\n\n  B \x07\n") == ["A", "B"]
    caps = wakeinfo.wake_capabilities(lambda cmd, t: (1, ""))
    assert not caps["known"] and caps["wifi_wake_from_sleep"] == "unknown"
    assert "unknown" in caps["summary"]


def test_default_runner_is_not_a_shell():
    with pytest.raises(ValueError):
        REAL_RUNNER(["cmd", "/c", "whoami"])
    with pytest.raises(ValueError):
        REAL_RUNNER(["powercfg", "/devicequery", "all_devices"])
