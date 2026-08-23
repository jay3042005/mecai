/// Tests for API address normalization.
///
/// This is the code path between "user types 192.168.1.11" and "the app reaches
/// the server". Getting it wrong produces a silent connection failure with no
/// indication that a missing `http://` was the cause, so the forgiving cases are
/// asserted explicitly.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const normalize = AppSettings.normalizeBaseUrl;

  group('bare hosts get a scheme and the default port', () {
    test('bare IPv4', () {
      expect(normalize('192.168.1.11'), 'http://192.168.1.11:8000');
    });

    test('bare hostname', () {
      expect(normalize('mecai.local'), 'http://mecai.local:8000');
    });

    test('IP with an explicit port keeps it', () {
      expect(normalize('192.168.1.11:9000'), 'http://192.168.1.11:9000');
    });

    test('scheme present but no port', () {
      expect(normalize('http://192.168.1.11'), 'http://192.168.1.11:8000');
    });
  });

  group('https is left alone', () {
    test('no port is appended to an https host', () {
      // Appending :8000 to a hosted URL would break it — 443 is already correct.
      expect(normalize('https://api.example.com'), 'https://api.example.com');
    });

    test('an explicit https port is preserved', () {
      expect(normalize('https://api.example.com:8443'), 'https://api.example.com:8443');
    });
  });

  group('forgiving input', () {
    test('surrounding whitespace is trimmed', () {
      expect(normalize('  192.168.1.11  '), 'http://192.168.1.11:8000');
    });

    test('trailing slashes are stripped so paths never double up', () {
      expect(normalize('http://192.168.1.11:8000/'), 'http://192.168.1.11:8000');
      expect(normalize('192.168.1.11///'), 'http://192.168.1.11:8000');
    });

    test('empty input falls back to the platform default', () {
      expect(normalize(''), AppSettings.platformDefaultBaseUrl());
      expect(normalize('   '), AppSettings.platformDefaultBaseUrl());
    });
  });

  group('normalization is stable', () {
    test('re-normalizing an already-normal URL is a no-op', () {
      // The settings screen writes the normalized form back into the field, so
      // this runs on its own output every time the user re-tests.
      const inputs = [
        '192.168.1.11',
        '192.168.1.11:9000',
        'https://api.example.com',
        'mecai.local',
      ];
      for (final input in inputs) {
        final once = normalize(input);
        expect(normalize(once), once, reason: 'not idempotent for "$input"');
      }
    });
  });

  group('platform default', () {
    test('is a usable absolute http URL', () {
      final url = AppSettings.platformDefaultBaseUrl();
      final uri = Uri.parse(url);
      expect(uri.hasScheme, isTrue);
      expect(uri.host, isNotEmpty);
      expect(uri.hasPort, isTrue);
    });

    test('never points at a LAN address it cannot know', () {
      // A guessed 192.168.x.x default would be wrong for almost everyone; the
      // loopback/emulator defaults are at least correct for one known case each.
      expect(
        AppSettings.platformDefaultBaseUrl(),
        anyOf(contains('127.0.0.1'), contains('10.0.2.2')),
      );
    });
  });

}
