/// The notification gate.
///
/// The bug this pins: a sustained SpO₂ around 90% fired a fresh max-importance
/// alarm roughly twice a second, because the old dedupe key included the noisy
/// value. Every test named "sustained" below fails if that regresses.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/alert_gate.dart';
import 'package:mecai_mobile/models/vitals.dart';

AcuteFlag _spo2(double pct, {Severity severity = Severity.critical}) => AcuteFlag(
      severity: severity,
      vital: 'SpO2',
      displayValue: '${pct.round()}%',
      threshold: 'below 90%',
      message: 'Blood oxygen is critically low.',
      recommendation: 'Seek emergency care now.',
    );

AcuteFlag _hr() => const AcuteFlag(
      severity: Severity.warning,
      vital: 'Heart rate',
      displayValue: '130 bpm',
      threshold: 'outside 50-120 bpm',
      message: 'Heart rate is outside the normal resting range.',
      recommendation: 'Rest for 5 minutes.',
    );

final _t0 = DateTime(2026, 8, 21, 12);

void main() {
  group('a sustained noisy finding notifies once', () {
    test('the 2 Hz storm is reduced to a single notification', () {
      final gate = AlertGate();
      // Ten minutes of a real desaturation, sampled at 2 Hz, wobbling by a
      // percent or two exactly as the sensor does.
      const values = [90.0, 89.0, 90.0, 91.0, 89.0, 90.0];
      var fired = 0;

      for (var tick = 0; tick < 1200; tick++) {
        final at = _t0.add(Duration(milliseconds: 500 * tick));
        fired += gate.due([_spo2(values[tick % values.length])], now: at).length;
      }

      // 1200 packets over 10 minutes: one notification when the finding has been
      // sustained, and one more as the repeat window elapses. Not 1200.
      expect(fired, lessThanOrEqualTo(2));
      expect(fired, greaterThanOrEqualTo(1),
          reason: 'a sustained critical finding must notify at least once');
    });

    test('a changing value alone does not re-notify', () {
      final gate = AlertGate();
      expect(gate.due([_spo2(90)], now: _t0), isEmpty);
      // Sustained, so this one fires.
      expect(
        gate.due([_spo2(90)], now: _t0.add(const Duration(seconds: 11))),
        hasLength(1),
      );
      // A different value, same finding, well inside the repeat window.
      expect(
        gate.due([_spo2(88)], now: _t0.add(const Duration(seconds: 12))),
        isEmpty,
        reason: 'the value must not be part of the dedupe key',
      );
    });
  });

  group('sustain window', () {
    test('a single transient sample never notifies', () {
      final gate = AlertGate();
      expect(gate.due([_spo2(89)], now: _t0), isEmpty);
      // Resolved before the sustain window elapsed — a motion artefact.
      expect(gate.due([], now: _t0.add(const Duration(seconds: 2))), isEmpty);
      // Recurs, and is treated as new: the clock restarts.
      expect(gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 3))),
          isEmpty);
    });

    test('nothing fires before the finding is sustained', () {
      final gate = AlertGate(sustainFor: const Duration(seconds: 10));
      for (var s = 0; s < 10; s++) {
        expect(
          gate.due([_spo2(89)], now: _t0.add(Duration(seconds: s))),
          isEmpty,
          reason: 'fired at ${s}s, before the 10s sustain window',
        );
      }
      expect(
        gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 10))),
        hasLength(1),
      );
    });
  });

  group('escalation', () {
    test('warning to critical notifies immediately, ignoring the cooldown', () {
      final gate = AlertGate();
      gate.due([_spo2(93, severity: Severity.warning)], now: _t0);
      expect(
        gate.due(
          [_spo2(93, severity: Severity.warning)],
          now: _t0.add(const Duration(seconds: 11)),
        ),
        hasLength(1),
      );
      // One second later, and far inside the 10-minute repeat window.
      expect(
        gate.due(
          [_spo2(88, severity: Severity.critical)],
          now: _t0.add(const Duration(seconds: 12)),
        ),
        hasLength(1),
        reason: 'worsening is new information and must not wait out a timer',
      );
    });

    test('de-escalation does not notify', () {
      final gate = AlertGate();
      gate.due([_spo2(88)], now: _t0);
      gate.due([_spo2(88)], now: _t0.add(const Duration(seconds: 11)));
      expect(
        gate.due(
          [_spo2(93, severity: Severity.warning)],
          now: _t0.add(const Duration(seconds: 12)),
        ),
        isEmpty,
      );
    });
  });

  group('repeat reminder', () {
    test('the same finding reminds once the window elapses', () {
      final gate = AlertGate(repeatAfter: const Duration(minutes: 10));
      gate.due([_spo2(89)], now: _t0);
      expect(gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 11))),
          hasLength(1));
      expect(gate.due([_spo2(89)], now: _t0.add(const Duration(minutes: 5))),
          isEmpty);
      expect(
        gate.due([_spo2(89)], now: _t0.add(const Duration(minutes: 10, seconds: 11))),
        hasLength(1),
      );
    });
  });

  group('info findings', () {
    test('never notify, however long they persist', () {
      final gate = AlertGate();
      const note = AcuteFlag(
        severity: Severity.info,
        vital: 'Temperature',
        displayValue: '35.8 C',
        threshold: 'below 36.1 C',
        message: 'Body temperature is slightly below normal.',
        recommendation: 'Warm up and re-measure.',
      );
      for (var m = 0; m < 60; m++) {
        expect(gate.due([note], now: _t0.add(Duration(minutes: m))), isEmpty);
      }
    });
  });

  group('independence and resolution', () {
    test('two vitals are tracked separately', () {
      final gate = AlertGate();
      gate.due([_spo2(89)], now: _t0);
      // Heart rate appears later, so its own sustain clock starts later.
      final due = gate.due(
        [_spo2(89), _hr()],
        now: _t0.add(const Duration(seconds: 11)),
      );
      expect(due.map((f) => f.vital), ['SpO2']);

      expect(
        gate
            .due([_spo2(89), _hr()], now: _t0.add(const Duration(seconds: 22)))
            .map((f) => f.vital),
        ['Heart rate'],
      );
    });

    test('a resolved finding that recurs is treated as new', () {
      final gate = AlertGate();
      gate.due([_spo2(89)], now: _t0);
      gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 11)));

      // Resolves.
      gate.due([], now: _t0.add(const Duration(seconds: 20)));

      // Recurs. The cooldown must not carry over, but the sustain window applies
      // again — so nothing at first sighting.
      expect(gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 30))),
          isEmpty);
      expect(
        gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 41))),
        hasLength(1),
        reason: 'a fresh episode must be able to alarm even inside the old '
            'repeat window',
      );
    });

    test('reset clears the cooldown', () {
      final gate = AlertGate();
      gate.due([_spo2(89)], now: _t0);
      gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 11)));
      gate.reset();

      expect(gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 12))),
          isEmpty);
      expect(
        gate.due([_spo2(89)], now: _t0.add(const Duration(seconds: 23))),
        hasLength(1),
      );
    });
  });
}
