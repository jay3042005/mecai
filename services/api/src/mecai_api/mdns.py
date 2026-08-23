"""LAN advertisement so the phone can find this server without typing an IP.

The single most common setup failure in the field is the server address: a
phone cannot reach ``127.0.0.1``, and reading the host's LAN IP off ``ipconfig``
to type into a small on-screen field is exactly the kind of step that goes
wrong. Advertising the service over mDNS/Bonjour (``_mecai._tcp``) lets the app
discover it instead — the same mechanism printers and AirPlay use, built into
Android via ``NsdManager`` and iOS via Bonjour.

Off by default? No — on by default, because the failure it prevents is silent.
Set ``MECAI_DISABLE_MDNS=true`` to stop advertising (air-gapped demos, shared
networks where announcing a health service is unwanted).
"""

from __future__ import annotations

import socket
import threading

#: Service type for the MEC-AI API. The trailing dot is part of the mDNS
#: convention; the phone's discovery must use the identical string.
SERVICE_TYPE = "_mecai._tcp.local."

#: Instance name shown to users and matched by the app. Kept stable: renaming
#: it between versions would leave an old install discovering nothing.
SERVICE_NAME = "MEC-AI Server"


def local_ip() -> str | None:
    """Best-effort LAN address, without sending any traffic.

    Opens a UDP "connection" to a public address purely so the OS routes it and
    reports which local address would be used — no packet leaves the machine,
    because UDP connect does not transmit. Loopback answers mean no network:
    return None rather than advertising 127.0.0.1, which a phone could never
    reach and which would make auto-discovery *worse* than asking.
    """
    probe: socket.socket | None = None
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.settimeout(0)
        probe.connect(("8.8.8.8", 80))
        ip = probe.getsockname()[0]
        return None if ip.startswith("127.") else ip
    except OSError:
        # Includes a refused socket *creation* — some sandboxes block even UDP.
        return None
    finally:
        if probe is not None:
            probe.close()


def build_service_info(port: int) -> tuple[str, str, int, dict[str, str]]:
    """Arguments for registering the service: (name, type, port, properties).

    Pure so tests can assert the advertisement shape without opening sockets or
    importing zeroconf at all.
    """
    props = {
        "version": "1",
        # The dashboard port rides along so one discovery serves both clients.
        "dashboard": str(port),
    }
    return (f"{SERVICE_NAME}.{SERVICE_TYPE}", SERVICE_TYPE, port, props)


class ServerAnnouncer:
    """Registers the service on start, unregisters cleanly on stop.

    Registration runs on a daemon thread and failures are swallowed: mDNS is a
    convenience, and a multicast-disabled network — or a sandboxed CI host where
    multicast can *block* rather than fail — must not take down, slow down, or
    wedge an otherwise healthy server.
    """

    def __init__(self, port: int, enabled: bool = True) -> None:
        self._port = port
        self._enabled = enabled
        self._lock = threading.Lock()
        self._zc: object | None = None
        self._info: object | None = None
        self._stopping = False

    def start(self) -> None:
        if not self._enabled:
            return
        self._stopping = False
        threading.Thread(target=self._register, name="mecai-mdns", daemon=True).start()

    def _register(self) -> None:
        try:
            from zeroconf import ServiceInfo, Zeroconf
        except ImportError:  # pragma: no cover - zeroconf ships as a hard dep
            return

        name, service_type, port, props = build_service_info(self._port)
        ip = local_ip()
        if ip is None or self._stopping:
            return
        info = ServiceInfo(
            service_type,
            name=name,
            addresses=[socket.inet_aton(ip)],
            port=port,
            properties=props,
            server="mecai-api.local.",
        )
        try:
            zc = Zeroconf()
            with self._lock:
                if self._stopping:
                    zc.close()
                    return
                zc.register_service(info)
                self._zc = zc
                self._info = info
        except OSError as error:  # pragma: no cover - depends on host network
            print(f"mDNS registration skipped: {error}")

    def stop(self) -> None:
        with self._lock:
            self._stopping = True
            zc, info = self._zc, self._info
            self._zc = None
            self._info = None
        if zc is None:
            return
        try:
            from zeroconf import ServiceInfo, Zeroconf

            if isinstance(zc, Zeroconf) and isinstance(info, ServiceInfo):
                zc.unregister_service(info)
        except Exception:  # noqa: BLE001 - teardown is best-effort by contract
            pass
        finally:
            zc.close()
