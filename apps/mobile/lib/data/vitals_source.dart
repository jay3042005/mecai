/// Device I/O boundary.
///
/// [VitalsSource] is the seam the real cuff slots into. Hardware is deferred, so
/// [MockVitalsSource] is what the app runs on today — but the interface is shaped
/// around the real device's constraints (a measurement takes ~30s, inflation
/// pressure streams during it, the link drops), not around the mock's
/// convenience. When `flutter_blue_plus` lands, `BleVitalsSource` implements this
/// and nothing above it changes.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/vitals.dart';

enum LinkState {
  disconnected,
  scanning,
  connecting,
  connected,
  streaming;

  String get label => switch (this) {
        LinkState.disconnected => 'Watch not connected',
        LinkState.scanning => 'Scanning for watch',
        LinkState.connecting => 'Connecting',
        LinkState.connected => 'Watch connected',
        LinkState.streaming => 'Live data streaming',
      };

  /// True when the watch is connected or actively streaming.
  bool get isLinked => this == LinkState.connected || this == LinkState.streaming;
}

/// One stage of a cuff measurement. Drives the Measure screen (docs/design.md §5.1).
enum MeasurePhase {
  prepare,
  inflating,
  measuring,
  releasing,
  done;

  /// Coaching line — what the user should be doing.
  String get label => switch (this) {
        MeasurePhase.prepare => 'Rest your arm and stay still',
        MeasurePhase.inflating => 'Inflating the cuff',
        MeasurePhase.measuring => 'Reading your pulse — stay still',
        MeasurePhase.releasing => 'Releasing pressure',
        MeasurePhase.done => 'Measurement complete',
      };

  /// Short all-caps stage name, shown where the risk band word normally sits so
  /// the ring's centre keeps a consistent shape across states.
  String get shortLabel => switch (this) {
        MeasurePhase.prepare => 'GET READY',
        MeasurePhase.inflating => 'INFLATING',
        MeasurePhase.measuring => 'MEASURING',
        MeasurePhase.releasing => 'RELEASING',
        MeasurePhase.done => 'COMPLETE',
      };

  /// True while the device is actively sensing, which is when the pulse ripples
  /// run. Inflation is mechanical; only this stage is "listening".
  bool get isSensing => this == MeasurePhase.measuring;
}

@immutable
class MeasureProgress {
  const MeasureProgress({
    required this.phase,
    required this.cuffPressureMmHg,
    required this.targetPressureMmHg,
  });

  final MeasurePhase phase;
  final double cuffPressureMmHg;
  final double targetPressureMmHg;

  /// Inflation shown as a meter, not a spinner — the user can see it progressing.
  double get inflationFraction =>
      targetPressureMmHg <= 0 ? 0 : (cuffPressureMmHg / targetPressureMmHg).clamp(0.0, 1.0);
}

abstract interface class VitalsSource {
  Stream<LinkState> get linkState;
  LinkState get currentLinkState;

  Future<void> connect();
  Future<void> disconnect();

  /// Run one measurement, streaming progress until a reading is produced.
  ///
  /// Streams rather than returning a bare Future because the cuff-pressure curve
  /// during inflation is itself part of the UI.
  Stream<MeasureProgress> measure();

  /// The reading produced by the last completed [measure], if any.
  VitalsReading? get lastReading;

  Future<List<VitalsReading>> history({Duration window = const Duration(hours: 24)});

  void dispose();
}

/// Which sensors the simulated device actually has.
///
/// Defaults to [firmware] deliberately. Developing against [complete] flatters the
/// app — every tile fills, the risk ring scores — and hides the states a real user
/// hits today: an unscorable ring and two empty tiles. Switch to [complete] only
/// to preview the finished device.
enum SensorCoverage {
  /// The device as specified: BP, HR, SpO2, body temperature.
  complete,

  /// What `MEC-AI3.ino` reports today: HR and SpO2 from the MAX30102, plus
  /// ambient air temperature from the SHT30x. No pressure sensor, no contact
  /// temperature sensor.
  firmware,
}

/// Synthetic source. Stands in for the ESP32 cuff until hardware lands.
///
/// Timings mirror a real oscillometric measurement (roughly 8s inflate, 12s
/// measure, 4s release) so the Measure screen's pacing is designed against
/// realistic durations rather than instant results.
class MockVitalsSource implements VitalsSource {
  MockVitalsSource({
    int? seed,
    this.scenario = MockScenario.normal,
    this.coverage = SensorCoverage.firmware,
  }) : _rng = Random(seed ?? 42);

  final Random _rng;
  final MockScenario scenario;
  final SensorCoverage coverage;

  final StreamController<LinkState> _link = StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;
  VitalsReading? _last;

  @override
  Stream<LinkState> get linkState => _link.stream;

  @override
  LinkState get currentLinkState => _state;

  @override
  VitalsReading? get lastReading => _last;

  void _setState(LinkState s) {
    _state = s;
    if (!_link.isClosed) _link.add(s);
  }

  @override
  Future<void> connect() async {
    _setState(LinkState.scanning);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _setState(LinkState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _setState(LinkState.connected);
  }

  @override
  Future<void> disconnect() async {
    _setState(LinkState.disconnected);
  }

  @override
  Stream<MeasureProgress> measure() async* {
    const target = 170.0;
    const tick = Duration(milliseconds: 120);

    yield const MeasureProgress(
      phase: MeasurePhase.prepare,
      cuffPressureMmHg: 0,
      targetPressureMmHg: target,
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // Inflate.
    for (double p = 0; p < target; p += target / 60) {
      yield MeasureProgress(
        phase: MeasurePhase.inflating,
        cuffPressureMmHg: p,
        targetPressureMmHg: target,
      );
      await Future<void>.delayed(tick);
    }

    // Measure on the way down — where the oscillometric signal actually lives.
    for (double p = target; p > 40; p -= target / 90) {
      yield MeasureProgress(
        phase: MeasurePhase.measuring,
        cuffPressureMmHg: p,
        targetPressureMmHg: target,
      );
      await Future<void>.delayed(tick);
    }

    for (double p = 40; p > 0; p -= 8) {
      yield MeasureProgress(
        phase: MeasurePhase.releasing,
        cuffPressureMmHg: p,
        targetPressureMmHg: target,
      );
      await Future<void>.delayed(tick);
    }

    _last = _synth(DateTime.now());
    yield const MeasureProgress(
      phase: MeasurePhase.done,
      cuffPressureMmHg: 0,
      targetPressureMmHg: target,
    );
  }

  @override
  Future<List<VitalsReading>> history({
    Duration window = const Duration(hours: 24),
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final now = DateTime.now();
    final count = max(1, window.inHours);
    return List<VitalsReading>.generate(
      count,
      (i) => _synth(now.subtract(Duration(hours: count - 1 - i)), circadian: true),
      growable: false,
    );
  }

  VitalsReading _synth(DateTime at, {bool circadian = false}) {
    final b = scenario.baseline;
    // Blood pressure dips overnight and peaks mid-morning; without this the
    // trend charts are noise around a flat line.
    final phase = circadian ? sin((at.hour - 4) / 24 * 2 * pi) : 0.0;

    final drift = _rng.nextDouble() * 2 - 1;
    var systolic = b.systolic + drift * 6 + phase * 5;
    var diastolic = b.diastolic + drift * 3 + phase * 3;
    if (systolic - diastolic < 20) diastolic = systolic - 20;

    final hasCuff = coverage == SensorCoverage.complete;

    return VitalsReading(
      // Absent, not zero, when the device has no pressure sensor.
      systolicMmHg: hasCuff ? double.parse(systolic.toStringAsFixed(1)) : null,
      diastolicMmHg: hasCuff ? double.parse(diastolic.toStringAsFixed(1)) : null,
      heartRateBpm:
          double.parse((b.heartRate + drift * 5 + phase * 4).toStringAsFixed(1)),
      spo2Pct: double.parse(min(100.0, b.spo2 + drift * 0.8).toStringAsFixed(1)),
      // Body temperature needs a contact sensor the firmware does not have.
      temperatureC:
          hasCuff ? double.parse((b.temperature + drift * 0.15).toStringAsFixed(2)) : null,
      // Typical Philippine indoor air, plus enclosure self-heating.
      ambientTempC: double.parse((28.5 + drift * 1.2).toStringAsFixed(2)),
      measuredAt: at,
      motionArtifact: _rng.nextDouble() < 0.06,
    );
  }

  @override
  void dispose() {
    _link.close();
  }
}

/// Named clinical pictures, so a demo can show a specific state on request.
///
/// Baselines match `services/api/src/mecai_api/mock.py` and sit clear of their
/// own thresholds by a comfortable margin — a baseline only 1σ from its cut-point
/// produces readings that contradict the scenario's name.
enum MockScenario {
  normal(VitalBaseline(114, 70, 72, 98, 36.8)),
  prehypertensive(VitalBaseline(136, 85, 78, 97, 36.9)),
  hypertensive(VitalBaseline(152, 96, 82, 96, 36.9)),
  crisis(VitalBaseline(196, 128, 95, 94, 37.1)),
  hypoxic(VitalBaseline(124, 79, 96, 88, 37.0)),
  febrile(VitalBaseline(122, 78, 104, 96, 38.6));

  const MockScenario(this.baseline);
  final VitalBaseline baseline;
}

/// Centre values a scenario varies around.
@immutable
class VitalBaseline {
  const VitalBaseline(
    this.systolic,
    this.diastolic,
    this.heartRate,
    this.spo2,
    this.temperature,
  );

  final double systolic;
  final double diastolic;
  final double heartRate;
  final double spo2;
  final double temperature;
}
