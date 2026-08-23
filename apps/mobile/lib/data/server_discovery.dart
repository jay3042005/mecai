/// Finds the MEC-AI scoring server on the local network, two ways.
///
/// The single most common setup failure in the field is the server address: a
/// phone cannot reach `127.0.0.1`, and typing the host's LAN IP into an
/// on-screen field is slow and error-prone — worse for someone whose hands
/// shake or whose vision is poor, which is not an edge case for the population
/// this device serves.
///
/// ### Strategy 1 — mDNS (`_mecai._tcp`)
///
/// The server announces itself (see `services/api/src/mecai_api/mdns.py`);
/// discovery uses Android's NsdManager via bonsoir, the path Google keeps
/// working on Android 10+. Fast when it works — but it depends on multicast
/// surviving the router *and* on Windows Firewall treating UDP 5353 kindly,
/// neither of which the app controls.
///
/// ### Strategy 2 — scan the Wi-Fi network
///
/// When nothing answers by name, every address on the phone's own subnet is
/// probed for `/health` and the response is fingerprint-checked against the
/// API's exact shape. This rides plain TCP, so it works wherever the phone can
/// reach the server at all — including networks where multicast dies silently,
/// which field testing showed is common. A home subnet sweeps in seconds.
library;

import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show InternetAddressType, NetworkInterface;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The service type the API advertises, as Android's NsdManager spells it.
///
/// Domain-less deliberately: NsdManager rejects the `.local.` suffix
/// ("invalid type"), which belongs to the *registration* spelling used by
/// python-zeroconf on the server (`_mecai._tcp.local.`). They name the same
/// service on the wire — mDNS always resolves inside .local.
const String mecaiServiceType = '_mecai._tcp';

/// Port the app expects the API on. Fixed by design; see [defaultApiPort].
const int mecaiServerPort = 8000;

/// One found scoring server.
@immutable
class DiscoveredServer {
  const DiscoveredServer({required this.name, required this.baseUrl});

  final String name;

  /// A ready-to-use base URL, e.g. `http://192.168.1.11:8000`.
  ///
  /// HTTP rather than HTTPS because the deployment target is a laptop or
  /// mini-PC on a home LAN with no certificate infrastructure; RA 10173's
  /// transport requirements apply to real deployments and are documented in
  /// the README, not solved here.
  final String baseUrl;

  @override
  String toString() => '$name ($baseUrl)';
}

/// Which strategy [discoverMecaiServer] is currently running.
enum DiscoveryStage {
  /// Listening for the server's mDNS announcement.
  mdns,

  /// Probing the subnet directly because no announcement was heard.
  scanning,
}

/// Finds a server: mDNS first, then a direct subnet scan.
///
/// Returns null only when *both* strategies come up empty — either the server
/// is off, or the phone is on a different network than it. [onStage] lets the
/// UI say which strategy is running, so "find server" never looks frozen.
Future<DiscoveredServer?> discoverMecaiServer({
  void Function(DiscoveryStage stage)? onStage,
  Duration mdnsTimeout = const Duration(seconds: 5),
}) async {
  onStage?.call(DiscoveryStage.mdns);
  final announced =
      await _discoverViaMdns(timeout: mdnsTimeout).timeout(
    mdnsTimeout + const Duration(seconds: 2),
    onTimeout: () => null,
  );
  if (announced != null) return announced;

  onStage?.call(DiscoveryStage.scanning);
  return scanLanForServer();
}

/// Whether a `/health` response body was produced by THIS api and not by some
/// other device that happens to serve JSON on port 8000 (routers do).
///
/// Deliberately strict: `status` alone would accept half the smart home on the
/// network; requiring `risk_model` matches a field only MEC-AI sends.
bool looksLikeMecaiHealth(Object? decoded) =>
    decoded is Map &&
    decoded['status'] == 'ok' &&
    decoded['risk_model'] is String &&
    decoded.containsKey('patients');

/// Every address worth probing on the phone's own IPv4 networks.
///
/// Assumes a /24 per interface — the shape of every home and clinic router
/// this device will meet. Link-local (169.254.x.x) ranges are skipped: they
/// mean "no real network", and sweeping one costs two seconds for nothing.
List<String> candidateHosts(Iterable<String> interfaceAddresses) {
  final hosts = <String>{};
  for (final address in interfaceAddresses) {
    final parts = address.split('.');
    if (parts.length != 4) continue;
    if (parts[0] == '169' && parts[1] == '254') continue;
    if (parts[0] == '127') continue;
    final base = '${parts[0]}.${parts[1]}.${parts[2]}';
    for (var i = 1; i <= 254; i++) {
      hosts.add('$base.$i');
    }
  }
  return hosts.toList(growable: false);
}

/// Probes [candidateHosts] in parallel for a MEC-AI API on [mecaiServerPort].
///
/// Runs its own bounded worker pool rather than one future per host: 254
/// simultaneous sockets trips Android's per-process connection limits, while
/// 64 workers clear a /24 in roughly a second of wall time when most hosts
/// refuse instantly.
Future<DiscoveredServer?> scanLanForServer({
  int workers = 64,
  Duration perRequestTimeout = const Duration(milliseconds: 700),
}) async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  final hosts = candidateHosts([
    for (final iface in interfaces)
      for (final addr in iface.addresses) addr.address,
  ]);
  if (hosts.isEmpty) return null;

  final client = http.Client();
  final completer = Completer<DiscoveredServer?>();
  var checked = 0;
  var next = 0;

  Future<void> worker() async {
    while (!completer.isCompleted && next < hosts.length) {
      final host = hosts[next++];
      try {
        final response = await client
            .get(
              Uri.parse('http://$host:$mecaiServerPort/health'),
            )
            .timeout(perRequestTimeout);
        if (completer.isCompleted) return;
        if (response.statusCode != 200) continue;
        Object? body;
        try {
          body = response.body.startsWith('{') ? jsonDecode(response.body) : null;
        } on FormatException {
          continue;
        }
        if (looksLikeMecaiHealth(body)) {
          debugPrint('ServerDiscovery: found server at $host');
          if (!completer.isCompleted) {
            completer.complete(
              DiscoveredServer(
                name: 'MEC-AI Server',
                baseUrl: 'http://$host:$mecaiServerPort',
              ),
            );
          }
          return;
        }
      } on Exception {
        // Refused, timed out, or unreachable — the normal answer for all but
        // one address. Costs nothing and counts nothing.
      } finally {
        checked++;
      }
    }
  }

  try {
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  } finally {
    client.close();
  }
  if (!completer.isCompleted) completer.complete(null);
  debugPrint('ServerDiscovery: scan finished, $checked hosts checked.');
  return completer.future;
}

/// Strategy 1: resolves [_mecai._tcp] announcements on this network.
///
/// Returns null on timeout, when nothing answers, or when the platform cannot
/// run discovery at all — all three mean "fall through to the scan", which is
/// the correct next step rather than an error to surface.
Future<DiscoveredServer?> _discoverViaMdns({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final BonsoirDiscovery discovery = BonsoirDiscovery(
    type: mecaiServiceType,
    printLogs: false,
  );

  try {
    await discovery.initialize();
    if (!discovery.isReady) return null;
    await discovery.start();

    final completer = Completer<DiscoveredServer?>();
    late final StreamSubscription<BonsoirDiscoveryEvent> subscription;
    subscription = discovery.eventStream!.listen(
      (event) {
        if (completer.isCompleted) return;
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent(:final service):
            // Found announcements carry only the name; resolution performs the
            // DNS exchange that produces the address.
            service.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryServiceResolvedEvent(:final service):
            final host = service.host;
            if (host != null && host.isNotEmpty) {
              completer.complete(
                DiscoveredServer(
                  name: service.name,
                  baseUrl: 'http://$host:${service.port}',
                ),
              );
            }
          default:
            break;
        }
      },
      // Discovery failures surface HERE as well as through start()'s future —
      // an unhandled stream error crashes the VM in debug builds. Treat it as
      // "not found": the subnet scan takes over from here.
      onError: (Object error) {
        debugPrint('ServerDiscovery: $error');
        if (!completer.isCompleted) completer.complete(null);
      },
      cancelOnError: true,
    );

    final result =
        await completer.future.timeout(timeout, onTimeout: () => null);
    await subscription.cancel();
    return result;
  } on Exception catch (error) {
    debugPrint('ServerDiscovery: mDNS unavailable. $error');
    return null;
  } finally {
    try {
      await discovery.stop();
    } on Exception catch (_) {}
  }
}
