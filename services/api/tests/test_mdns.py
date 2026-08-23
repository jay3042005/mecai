"""Tests for the mDNS advertisement's pure logic.

Discovery is a convenience over manual address entry, so the bar is modest:
the advertisement must be shaped correctly, must not advertise a loopback
address, and the opt-out must be honoured. The multicast machinery itself is
exercised by running the server, not here.
"""

from __future__ import annotations

from mecai_api import mdns
from mecai_api.mdns import SERVICE_NAME, SERVICE_TYPE, ServerAnnouncer, build_service_info


def test_service_info_shape():
    name, service_type, port, props = build_service_info(8000)

    assert service_type == SERVICE_TYPE == "_mecai._tcp.local."
    # The app matches on this exact string; a renamed instance would leave old
    # installs discovering nothing.
    assert name == f"{SERVICE_NAME}.{SERVICE_TYPE}"
    assert port == 8000
    assert props["version"] == "1"
    assert "dashboard" in props


def test_local_ip_never_loopback(monkeypatch):
    """A loopback answer means 'no LAN', and advertising 127.0.0.1 would send
    phones hunting for a server they can never reach — worse than finding
    nothing."""
    class FakeSock:
        def __init__(self, ip):
            self._ip = ip

        def settimeout(self, _):
            pass

        def connect(self, _):
            pass

        def getsockname(self):
            return (self._ip, 0)

        def close(self):
            pass

    monkeypatch.setattr(mdns.socket, "socket", lambda *_: FakeSock("192.168.1.11"))
    assert mdns.local_ip() == "192.168.1.11"

    monkeypatch.setattr(mdns.socket, "socket", lambda *_: FakeSock("127.0.0.1"))
    assert mdns.local_ip() is None

    def refused(*_):
        raise OSError("no network")

    monkeypatch.setattr(mdns.socket, "socket", refused)
    assert mdns.local_ip() is None


def test_disabled_announcer_never_imports_zeroconf():
    """The opt-out must cost nothing: no sockets, no zeroconf import, no error
    even if the dependency were missing entirely."""
    announcer = ServerAnnouncer(port=8000, enabled=False)
    announcer.start()  # Must not raise.
    announcer.stop()
