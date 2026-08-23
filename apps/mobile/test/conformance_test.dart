/// Cross-language conformance for local acute-flag evaluation.
///
/// This app evaluates alerts on-device so an SpO2 of 88% raises an emergency without
/// a network — see `lib/data/acute_flags.dart` for why. That means two
/// implementations of one clinical rule set, here and in the Python service.
///
/// `packages/tokens/alert-conformance.json` is the contract both must satisfy, and it
/// is generated from the same thresholds both read. The Python twin of this file is
/// `services/api/tests/test_conformance.py`. If these two ever disagree about a
/// reading, one of them is wrong and this test says so.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/acute_flags.dart';
import 'package:mecai_mobile/design/tokens.dart';
import 'package:mecai_mobile/models/vitals.dart';

/// Relative to the package root, which is `flutter test`'s working directory.
final _fixture = File('../../packages/tokens/alert-conformance.json');

List<Map<String, dynamic>> _loadCases() {
  if (!_fixture.existsSync()) {
    fail(
      'Conformance fixture missing at ${_fixture.absolute.path}. '
      'Run: node packages/tokens/generate.mjs',
    );
  }
  final decoded = jsonDecode(_fixture.readAsStringSync()) as Map<String, dynamic>;
  return (decoded['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
}

void main() {
  final cases = _loadCases();

  test('fixture is populated', () {
    // Guards against an empty fixture silently passing every case below.
    expect(cases.length, greaterThanOrEqualTo(30));
  });

  group('conformance', () {
    for (final c in cases) {
      final id = c['id'] as String;
      final expected = c['expect'] as Map<String, dynamic>?;

      test(id, () {
        final reading =
            VitalsReading.fromJson(c['reading'] as Map<String, dynamic>);
        final flags = evaluateAcuteFlags(reading);

        final actual =
            flags.map((f) => '${f.vital}/${f.severity.name}').toList();

        if (expected == null) {
          expect(flags, isEmpty, reason: '$id: expected no flag, got $actual');
          return;
        }

        // Every fixture reading carries a single vital (or one BP pair), so
        // exactly one flag is correct — more would mean double evaluation.
        expect(
          flags,
          hasLength(1),
          reason: '$id: expected exactly one flag, got $actual',
        );

        expect(flags.first.vital, expected['vital'], reason: '$id: wrong vital');
        expect(
          flags.first.severity.name,
          expected['severity'],
          reason: '$id: wrong severity',
        );
      });
    }
  });

  group('flag content', () {
    test('every flag carries message, threshold, and recommendation', () {
      // A flag that says something is wrong but not what to do is half a feature.
      for (final c in cases) {
        if (c['expect'] == null) continue;
        final reading =
            VitalsReading.fromJson(c['reading'] as Map<String, dynamic>);
        final flag = evaluateAcuteFlags(reading).first;

        expect(flag.message.trim(), isNotEmpty, reason: '${c['id']}: message');
        expect(flag.recommendation.trim(), isNotEmpty,
            reason: '${c['id']}: recommendation');
        // The threshold is what makes an alert legible without relying on colour.
        expect(flag.threshold.trim(), isNotEmpty, reason: '${c['id']}: threshold');
      }
    });
  });

  group('generated constants match the fixture source', () {
    test('alert cut-points came from tokens.json', () {
      // A sanity check that codegen ran: if MecAlert were hand-edited away from
      // tokens.json, the conformance cases above would start failing — but this
      // catches the specific case of stale generated output.
      expect(MecAlert.spo2Critical, 90.0);
      expect(MecAlert.spo2Warning, 95.0);
      expect(MecAlert.bloodPressureCrisisSystolic, 180.0);
      expect(MecAlert.temperatureHypothermiaCritical, 35.0);
      expect(MecAlert.heartRateHighCritical, 150.0);
    });
  });
}
