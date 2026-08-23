/// Guards the mDNS service-type spelling.
///
/// This exact string caused a production bug once: `_mecai._tcp.local.` is the
/// *registration* spelling python-zeroconf uses server-side, but Android's
/// NsdManager — bonsoir's backing API — rejects the domain suffix, killing
/// discovery at start(). These assertions keep both halves of that contract
/// visible at test time.
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
}
