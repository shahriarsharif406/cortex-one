"""Where the agent may listen, and how it keeps listening when an address is not up yet.

Allowed bind addresses (anything else is rejected with a clear error):
- loopback 127.0.0.0/8 (and ``localhost``, which is turned into 127.0.0.1)
- Tailscale 100.64.0.0/10
- private LAN ranges 10/8, 172.16/12, 192.168/16, but only because the owner
  listed them in ``hosts`` / ``host`` of config.json (nothing is ever guessed)

Never 0.0.0.0, ``::``, an empty string, a host name or a public address.

``BindManager`` serves on every configured address. If an address (typically the
Tailscale IP) is not present yet at boot it waits with exponential backoff (up to
10 minutes), keeps retrying, and binds as soon as the address appears. It never
falls back to another address.
"""
from __future__ import annotations

import ipaddress
import logging
import threading
import time
from typing import Any, Callable, Protocol

log = logging.getLogger("cortex.bind")

MAX_BACKOFF = 600.0          # 10 minutes
MAX_HOSTS = 8

_TAILSCALE = ipaddress.ip_network("100.64.0.0/10")
_PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
_LOOPBACK = ipaddress.ip_network("127.0.0.0/8")


class BindError(ValueError):
    """A configured bind address is not allowed. The message is safe to show."""


def classify_address(addr: str) -> str:
    """'loopback' | 'tailscale' | 'lan' | 'other'. Pure string check, no network."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return "other"
    if not isinstance(ip, ipaddress.IPv4Address):
        return "other"
    if ip in _LOOPBACK:
        return "loopback"
    if ip in _TAILSCALE:
        return "tailscale"
    if any(ip in net for net in _PRIVATE):
        return "lan"
    return "other"


def check_bind_address(addr: Any) -> str:
    """Return the normalised address or raise BindError."""
    if not isinstance(addr, str) or not addr.strip():
        raise BindError("A bind address must be a non-empty text like \"100.101.102.103\".")
    text = addr.strip()
    if text.lower() == "localhost":
        return "127.0.0.1"
    if not text.isascii() or any(c.isspace() for c in text):
        raise BindError("A bind address must be a plain IPv4 address.")
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        raise BindError(f"'{text[:40]}' is not an IP address. Use 127.0.0.1, your Tailscale IP "
                        f"(100.64.0.0/10) or a private LAN IP.")
    if ip.is_unspecified:
        raise BindError("0.0.0.0 / :: is not allowed: it exposes the agent on every network. "
                        "List the Tailscale IP and, if needed, the LAN IP instead.")
    kind = classify_address(str(ip)) if isinstance(ip, ipaddress.IPv4Address) else "other"
    if kind == "other":
        raise BindError(f"'{text[:40]}' is not allowed. Allowed: 127.0.0.1, Tailscale "
                        f"100.64.0.0/10, private LAN (10/8, 172.16/12, 192.168/16).")
    return str(ip)


def effective_hosts(settings: Any) -> list[str]:
    """Validated, de-duplicated bind list: ``hosts`` when set, else the old single ``host``."""
    raw = getattr(settings, "hosts", None) or []
    if raw and not isinstance(raw, list):
        raise BindError("hosts must be a list of addresses.")
    if not raw:
        raw = [settings.host]
    if len(raw) > MAX_HOSTS:
        raise BindError(f"At most {MAX_HOSTS} bind addresses are allowed.")
    out: list[str] = []
    for item in raw:
        norm = check_bind_address(item)
        if norm not in out:
            out.append(norm)
    return out


def local_addresses() -> set[str]:
    """IPv4 addresses currently assigned to this computer (psutil; read-only)."""
    found: set[str] = set()
    try:
        import psutil

        for addrs in psutil.net_if_addrs().values():
            for a in addrs:
                if getattr(a.family, "name", "") == "AF_INET" or a.family == 2:
                    found.add(a.address)
    except Exception:
        pass
    return found


class ServerHandle(Protocol):
    def serve(self) -> None: ...       # blocks until the server stops
    def request_stop(self) -> None: ...


def uvicorn_factory(app: Any) -> Callable[[str, int], ServerHandle]:
    """Real servers: one uvicorn.Server per address, each run in its own thread."""
    import uvicorn

    class _Handle:
        def __init__(self, host: str, port: int):
            cfg = uvicorn.Config(app, host=host, port=port, log_config=None, log_level="info")
            self.server = uvicorn.Server(cfg)

        def serve(self) -> None:
            self.server.run()

        def request_stop(self) -> None:
            self.server.should_exit = True

    return lambda host, port: _Handle(host, port)


class BindManager:
    """One worker thread per address. Every wait is interruptible by ``stop()``."""

    def __init__(self, hosts: list[str], port: int,
                 make_server: Callable[[str, int], ServerHandle],
                 interfaces: Callable[[], set[str]] = local_addresses,
                 base_delay: float = 2.0, max_delay: float = MAX_BACKOFF,
                 poll: float = 5.0):
        for h in hosts:
            check_bind_address(h)            # a manager can never be built with a bad address
        self.hosts, self.port = list(hosts), port
        self.make_server, self.interfaces = make_server, interfaces
        self.base_delay, self.max_delay, self.poll = base_delay, max_delay, poll
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self.status: dict[str, str] = {h: "waiting" for h in hosts}   # waiting|up|retrying
        self.attempts: dict[str, int] = {h: 0 for h in hosts}

    # an address is usable when it is loopback or currently assigned to an interface
    def _present(self, host: str) -> bool:
        if classify_address(host) == "loopback":
            return True
        try:
            return host in self.interfaces()
        except Exception:
            return False

    def _run_host(self, host: str) -> None:
        delay = self.base_delay
        while not self._stop.is_set():
            if not self._present(host):
                self.status[host] = "waiting"
                log.warning("address %s is not up yet; retrying in %.0fs", host, delay)
                if self._stop.wait(delay):
                    return
                delay = min(delay * 2, self.max_delay)
                continue
            self.attempts[host] += 1
            handle = self.make_server(host, self.port)
            ended = threading.Event()

            def serve() -> None:
                try:
                    handle.serve()
                except BaseException as exc:      # uvicorn exits with SystemExit on a bind error
                    log.warning("server on %s stopped (%s)", host, type(exc).__name__)
                finally:
                    ended.set()

            t = threading.Thread(target=serve, name=f"serve-{host}", daemon=True)
            t.start()
            self.status[host] = "up"
            log.info("serving on %s:%s", host, self.port)
            began = time.monotonic()
            while not ended.wait(self.poll):
                if self._stop.is_set() or not self._present(host):
                    if not self._stop.is_set():
                        log.warning("address %s went away; stopping that listener", host)
                    handle.request_stop()
                    ended.wait(10)
                    break
            if self._stop.is_set():
                handle.request_stop()
                return
            self.status[host] = "retrying"
            if time.monotonic() - began > 60:     # ran healthily: retry fast, not after 10 min
                delay = self.base_delay
            if self._stop.wait(delay):
                return
            delay = min(delay * 2, self.max_delay)

    def start(self) -> None:
        for h in self.hosts:
            t = threading.Thread(target=self._run_host, args=(h,), name=f"bind-{h}", daemon=True)
            t.start()
            self._threads.append(t)

    def stop(self) -> None:
        self._stop.set()

    def join(self) -> None:
        """Block the caller (the main thread) until stop() or Ctrl+C."""
        try:
            while not self._stop.wait(0.5):
                pass
        except KeyboardInterrupt:
            self.stop()
