/// Tests for the emergency message and the contact list.
///
/// The message is the part that has to be right: a responder reads it once, on a
/// phone, possibly in a hurry. So these pin down that the emergency comes first,
/// that the map link survives intact, and — the case most likely to be got wrong —
/// that a missing GPS fix produces an explicit "location unavailable" rather than
/// silence that reads as "no location was needed".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/emergency_contacts.dart';
import 'package:mecai_mobile/data/location_service.dart';
import 'package:mecai_mobile/data/sos_dispatcher.dart';

const _tacurong = LocationFix(
  latitude: 6.6925,
  longitude: 124.6774,
  accuracyM: 12,
  quality: FixQuality.live,
);

void main() {
  group('message composition', () {
    test('leads with the emergency, not a greeting', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
      );
      // A notification preview shows the first line and little else.
      expect(message.split('\n').first, startsWith('EMERGENCY'));
    });

    test('names the patient', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
      );
      expect(message, contains('R. Bautista'));
    });

    test('carries a Google Maps link to the coordinates', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
      );
      expect(message, contains('https://www.google.com/maps/search/'));
      expect(message, contains('6.692500,124.677400'));
    });

    test('puts the link on its own line', () {
      // Messaging apps swallow trailing punctuation into a URL, which breaks the
      // one part of the message that has to work.
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
      );
      final linkLine = message
          .split('\n')
          .firstWhere((line) => line.contains('google.com/maps'));
      expect(linkLine, equals(_tacurong.mapsUrl));
    });

    test('includes the vitals when they are known', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
        heartRateBpm: 118.4,
        spo2Pct: 87.6,
      );
      expect(message, contains('118 bpm'));
      expect(message, contains('88%'));
    });

    test('omits the vitals line entirely when nothing was measured', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
      );
      // Rather than "heart rate: —", which reads as a failed sensor mid-emergency.
      expect(message, isNot(contains('Last reading')));
    });

    test('says so explicitly when there is no location', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: const LocationFix.unavailable(problem: 'Location is switched off.'),
      );
      expect(message, contains('Location unavailable'));
      expect(message, contains('call me'));
      expect(message, isNot(contains('google.com/maps')));
    });

    test('labels a stale fix as last known', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: const LocationFix(
          latitude: 6.6925,
          longitude: 124.6774,
          quality: FixQuality.lastKnown,
        ),
      );
      // Presenting an old position as current could send help to the wrong place.
      expect(message, contains('last known location'));
    });

    test('always ends with an explicit ask', () {
      final message = SosDispatcher.composeMessage(
        patientName: 'R. Bautista',
        fix: _tacurong,
      );
      expect(message.trim(), endsWith('Please call me or send help.'));
    });
  });

  group('location fix', () {
    test('reports no position when coordinates are absent', () {
      const fix = LocationFix.unavailable();
      expect(fix.hasPosition, isFalse);
      expect(fix.mapsUrl, isNull);
      expect(fix.coordinatesLabel, '—');
    });

    test('formats coordinates in the conventional order', () {
      expect(_tacurong.coordinatesLabel, '6.69250, 124.67740');
    });

    test('uses an https link rather than a geo: URI', () {
      // An SMS may be read on a desktop or a phone with no maps app registered
      // for geo:; an https link always opens something.
      expect(_tacurong.mapsUrl, startsWith('https://'));
    });
  });

  group('phone normalisation', () {
    test('strips the spacing people actually type', () {
      expect(EmergencyContacts.normalizePhone('0917 123 4567'), '09171234567');
      expect(EmergencyContacts.normalizePhone('0917-123-4567'), '09171234567');
      expect(EmergencyContacts.normalizePhone('(0917) 123 4567'), '09171234567');
    });

    test('keeps a leading plus for international form', () {
      expect(EmergencyContacts.normalizePhone('+63 917 123 4567'), '+639171234567');
    });

    test('drops a plus that is not leading', () {
      expect(EmergencyContacts.normalizePhone('0917+1234567'), '09171234567');
    });

    test('accepts short codes', () {
      expect(EmergencyContacts.isPlausiblePhone('911'), isTrue);
    });

    test('accepts a full mobile number in either form', () {
      expect(EmergencyContacts.isPlausiblePhone('0917 123 4567'), isTrue);
      expect(EmergencyContacts.isPlausiblePhone('+63 917 123 4567'), isTrue);
    });

    test('rejects something that cannot be dialled', () {
      expect(EmergencyContacts.isPlausiblePhone(''), isFalse);
      expect(EmergencyContacts.isPlausiblePhone('no'), isFalse);
      expect(EmergencyContacts.isPlausiblePhone('12'), isFalse);
    });
  });

  group('dispatch outcomes', () {
    const dispatcher = SosDispatcher();

    test('an empty contact list is reported, not silently skipped', () async {
      final result = await dispatcher.sendEmergencySms(
        contacts: const [],
        message: 'help',
      );
      expect(result.outcome, DispatchOutcome.noContacts);
      expect(result.outcome.delivered, isFalse);
    });

    test('an unsupported platform is reported distinctly from a failure', () async {
      // The test host is not Android, so this exercises the platform guard. The
      // distinction matters: "this phone cannot" needs different words to "the
      // message did not go".
      final result = await dispatcher.sendEmergencySms(
        contacts: const [EmergencyContact(name: 'Maria', phone: '09171234567')],
        message: 'help',
      );
      expect(result.outcome, DispatchOutcome.unsupported);
      // The composed text is returned regardless, so the UI can still show what
      // *would* have been sent.
      expect(result.message, 'help');
    });

    test('only Android can send without user interaction', () {
      // iOS exposes no programmatic SMS API at all, so the guard is a platform
      // check rather than a runtime failure.
      expect(SosDispatcher.isSupported, isFalse);
    });

    test('delivered is true only for sent and partial', () {
      expect(DispatchOutcome.sent.delivered, isTrue);
      expect(DispatchOutcome.partial.delivered, isTrue);
      expect(DispatchOutcome.failed.delivered, isFalse);
      expect(DispatchOutcome.permissionDenied.delivered, isFalse);
      expect(DispatchOutcome.noContacts.delivered, isFalse);
      expect(DispatchOutcome.unsupported.delivered, isFalse);
    });

    test('every outcome has a human label', () {
      for (final outcome in DispatchOutcome.values) {
        expect(outcome.label, isNotEmpty);
      }
    });
  });
}
