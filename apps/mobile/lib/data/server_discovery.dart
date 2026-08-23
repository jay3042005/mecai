/// Finds the MEC-AI scoring server on the local network, by name.
///
/// The server advertises itself as `_mecai._tcp` (see
/// `services/api/src/mecai_api/mdns.py`). Discovery replaces the setup step that
/// failed most often in practice: a phone cannot reach `127.0.0.1`, and typing
/// the host's LAN IP into an on-screen field is slow and error-prone — worse for
/// someone whose hands shake or whose vision is poor, which is not an edge case
/// for the population this device serves.
///
/// ### Why bonsoir (NsdManager) rather than raw multicast
///
/// Android 10 hardened network discovery, and packet-level mDNS from an app no
/// longer sees responses reliably without multicast locks and specific routing.
/// `NsdManager` — Android's own service-discovery API, which bonsoir wraps — is
/// the path Google keeps working across versions, including 10 through current;
/// it handles the multicast plumbing internally. iOS and macOS use Bonjour
/// natively through the same plugin.
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

/// The service type the API advertises, as Android's NsdManager spells it.
///
/// Domain-less deliberately: NsdManager rejects the `.local.` suffix
/// ("invalid type"), which belongs to the *registration* spelling used by
/// python-zeroconf on the server (`_mecai._tcp.local.`). They name the same
/// service on the wire — mDNS always resolves inside .local.
const String mecaiServiceType = '_mecai._tcp';

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

/// Resolves `_mecai._tcp` to the first server answering before [timeout].
///
/// Returns null on timeout, on no result, or when the platform cannot run
/// discovery at all — all three mean "keep whatever address is configured",
/// which is the correct fallback: discovery is a convenience over manual entry,
/// never a gate in front of it.
Future<DiscoveredServer?> discoverMecaiServer({
  Duration timeout = const Duration(seconds: 6),
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
      // "not found": discovery is a convenience over typing the address.
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
    debugPrint('ServerDiscovery: unavailable on this platform/network. $error');
    return null;
  } finally {
    try {
      await discovery.stop();
    } on Exception catch (_) {}
  }
}
