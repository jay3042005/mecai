/// Guards the auto-find feature's pure logic: the mDNS type spelling that
/// NsdManager accepts, the /health fingerprint that keeps a router's admin
/// page from being adopted as a scoring server, and the subnet sweep list.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/server_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('service type is NsdManager-shaped: _name._tcp without a domain', () {
    expect(mecaiServiceType, startsWith('_'));
    expect(mecaiServiceType, endsWith('._tcp'));
    // The registration-side suffix must never leak into discovery — NsdManager
    // refuses it and bonsoir then fails before any server is found.
    expect(mecaiServiceType.endsWith('.local.'), isFalse);
    expect(RegExp(r'^_[a-z0-9-]+\._tcp$').hasMatch(mecaiServiceType), isTrue);
  });

  group('looksLikeMecaiHealth', () {
    const real = {
      'status': 'ok',
      'version': '0.1.0',
      'risk_model': 'framingham-general-cvd-2008',
      'mock_endpoints': false,
      'storage': true,
      'patients': 6,
      'readings': 576,
    };

    test('accepts the API\'s own health body', () {
      expect(looksLikeMecaiHealth(real), isTrue);
    });

    test('rejects look-alike JSON from other devices on port 8000', () {
      // Routers, printers and dev servers all answer :8000 with JSON.
      expect(looksLikeMecaiHealth({'status': 'ok'}), isFalse);
      expect(
        looksLikeMecaiHealth({
          'status': 'ok',
          'message': 'Welcome to nginx!',
        }),
        isFalse,
      );
      expect(looksLikeMecaiHealth({'risk_model': 'fake'}), isFalse);
      expect(looksLikeMecaiHealth('ok'), isFalse);
      expect(looksLikeMecaiHealth(null), isFalse);
    });
  });

  group('candidateHosts', () {
    test('expands one /24 into every host, no network or broadcast address', () {
      final hosts = candidateHosts(['192.168.1.58']);
      expect(hosts, hasLength(254));
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
      expect(hosts, contains('192.168.1.11'));
    });

    test('skips link-local and loopback interfaces', () {
      final hosts = candidateHosts([
        '169.254.12.34', // no route — sweeping it costs seconds for nothing
        '127.0.0.1', // this phone
      ]);
      expect(hosts, isEmpty);
    });

    test('unions multiple interfaces without duplicates', () {
      final hosts = candidateHosts(['192.168.1.58', '192.168.43.100']);
      expect(hosts, hasLength(508));
    });

    test('ignores non-IPv4 input', () {
      expect(candidateHosts(['fe80::1']), isEmpty);
    });
  });
}
