/// Tests for the sample-data generator: the properties a demo dataset needs
/// before it is safe to press the button on.
///
/// The dangerous failure modes are specific: values that cross an acute
/// threshold teach alarm fatigue; non-deterministic ids double the history on
/// the server's uniqueness constraint instead of deduplicating against it; and
/// a claimed systolic pressure would make the dashboard look like hardware it
/// does not have.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/acute_flags.dart';
import 'package:mecai_mobile/data/sample_data.dart';
import 'package:mecai_mobile/models/vitals.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const patientId = '11111111-2222-3333-4444-555555555555';
  final end = DateTime.utc(2026, 8, 23, 10, 0);

  List<VitalsReading> series({Random? rng, DateTime? endAt}) =>
      generateSampleReadings(
        patientId: patientId,
        end: endAt ?? end,
        rng: rng,
        hours: 48,
      );

  group('generateSampleReadings', () {
    test('produces one reading per slot, oldest first, ending at the anchor',
        () {
      final readings = series();

      expect(readings, hasLength(48 * 60 ~/ 30));
      // Timestamps snap to the 30-minute grid measured from the epoch — what
      // makes regeneration idempotent rather than additive.
      expect(
        readings.last.measuredAt.millisecondsSinceEpoch %
            (30 * 60 * 1000),
        0,
      );
      for (var i = 1; i < readings.length; i++) {
        expect(
          readings[i].measuredAt.difference(readings[i - 1].measuredAt),
          sampleSlot,
        );
      }
    });

    test('never crosses an acute threshold', () {
      for (final reading in series()) {
        // The property that matters most: demo data must never raise an
        // alarm, here or on the dashboard it backs up to.
        expect(evaluateAcuteFlags(reading), isEmpty,
            reason: 'reading at ${reading.measuredAt} tripped an alert');
      }
    });

    test('carries only vitals the firmware reports — never a fake cuff',
        () {
      for (final reading in series()) {
        expect(reading.systolicMmHg, isNull);
        expect(reading.diastolicMmHg, isNull);
        expect(reading.temperatureC, isNull);
        expect(reading.heartRateBpm, isNotNull);
        expect(reading.spo2Pct, isNotNull);
        expect(reading.ambientTempC, isNotNull);
      }
    });

    test('has circadian shape rather than flat noise', () {
      final readings = series();
      final byHour = <int, double>{};
      for (final reading in readings) {
        byHour.update(
          reading.measuredAt.hour,
          (v) => v + (reading.heartRateBpm!),
          ifAbsent: () => reading.heartRateBpm!,
        );
      }
      final means = byHour.map((h, sum) => MapEntry(h, sum / 2)); // 2 days

      final dayMean =
          (means[14]! + means[15]!) / 2; // mid-afternoon peak
      final nightMean = (means[3]! + means[4]!) / 2; // pre-dawn dip
      expect(dayMean - nightMean, greaterThan(3),
          reason: 'a flat line renders as a dead sensor, not a worn one');
    });

    test('same seed produces identical shape; ids are pure timestamp math',
        () {
      final a = series(rng: Random(7));
      final b = series(rng: Random(7));
      expect(a.map((r) => r.toJson()), b.map((r) => r.toJson()));

      // Ids depend only on patient + timestamp, so two runs of the generator
      // — or two devices seeding the same person — agree on them.
      expect(sampleClientId(patientId, a.first.measuredAt),
          sampleClientId(patientId, a.first.measuredAt));
      expect(sampleClientId('other-person', a.first.measuredAt),
          isNot(sampleClientId(patientId, a.first.measuredAt)));
    });

    test('ids are UUID-shaped with version and variant bits set', () {
      final id = sampleClientId(patientId, DateTime.utc(2026, 8, 23));
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(pattern.hasMatch(id), isTrue, reason: id);
      // Within the server's client_id bound.
      expect(id.length, lessThanOrEqualTo(64));
    });
  });
}
