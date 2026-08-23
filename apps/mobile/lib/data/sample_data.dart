/// Generates plausible back-dated readings for demos and profiling.
///
/// The point is a dashboard and trend charts that show *shape* — circadian
/// heart rate, gentle SpO₂ variation, ambient temperature drifting with the
/// room — without anyone wearing a watch for two days first. Used by the
/// "sample data" control in Settings; everything it writes goes through the
/// normal archive and the normal backup, so the server-side path exercised is
/// exactly the one real readings take.
///
/// ### Honest by construction
///
/// * Only fields the current firmware reports are filled: HR, SpO₂, ambient.
///   No systolic pressure — the device has no cuff, and sample rows that
///   claimed one would make the dashboard look like hardware it does not have.
/// * Values stay clear of every acute threshold (see `acute_flags.dart`):
///   SpO₂ never dips below 92, heart rate stays inside 55–110. A demo that
///   fires critical alarms — on the phone or on the clinician dashboard after
///   backup — teaches people to ignore alarms, which is the one lesson this
///   app must never teach.
///
/// ### Idempotency
///
/// Reading ids derive from the patient id and the timestamp's grid slot, not
/// from randomness. Regenerating inside an already-seeded window produces ids
/// the server has seen, so its `(patient_id, client_id)` uniqueness turns the
/// re-run into duplicates rather than a doubled history. Timestamps snap to a
/// fixed grid measured from the Unix epoch for the same reason `now`-offsets
/// would defeat it: every run would mint fresh slots and fresh history.
library;

import 'dart:math';

import '../models/vitals.dart';
import 'reading_store.dart' show generateClientId;

/// How far back the sample history reaches.
const Duration sampleWindow = Duration(hours: 48);

/// One reading per slot. Thirty minutes over 48 hours is 96 rows — enough for
/// the charts to carry shape, few enough to upload in a single batch.
const Duration sampleSlot = Duration(minutes: 30);

/// Deterministic UUID-shaped id for a reading at [measuredAt].
///
/// Two independently-mixed 64-bit hashes of the seed give 128 bits, formatted
/// in the same shape [generateClientId] produces (version nibble and variant
/// bits set). Not cryptographic — nothing here depends on that — only stable
/// across runs, which randomness cannot be.
// ignore: long-method
String sampleClientId(String patientId, DateTime measuredAt) {
  final seed = '$patientId:${measuredAt.toUtc().toIso8601String()}';
  var lo = 0xcbf29ce484222325; // FNV-1a offset basis
  var hi = 0x9e3779b97f4a7c15; // golden-ratio base
  for (final code in seed.codeUnits) {
    lo = _mix64(lo ^ code);
    hi = _mix64(hi ^ (code + 0x9e));
  }

  String hex(int value) => value.toRadixString(16).padLeft(16, '0');
  const variant = ['8', '9', 'a', 'b'];
  final hiHex = hex(hi);
  final mixed = hex(hi ^ lo);

  return '${hex(lo).substring(0, 8)}-' // time_low stand-in
      '${hex(lo).substring(8, 12)}-' // time_mid
      '4${hiHex.substring(1, 4)}-' // version 4
      '${variant[(hi >> 62) & 0x03]}${hiHex.substring(5, 8)}-' // clock_seq
      '${mixed.substring(0, 12)}'; // node
}

/// SplitMix64-style finalizer; avalanche so neighbouring slots diverge.
int _mix64(int x) {
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9 & 0xFFFFFFFFFFFFFFFF;
  x = (x ^ (x >> 27)) * 0x94d049bb133111eb & 0xFFFFFFFFFFFFFFFF;
  return (x ^ (x >> 31)) & 0xFFFFFFFFFFFFFFFF;
}

/// Builds the sample series: oldest first, ending at the most recent completed
/// [sampleSlot] boundary before [end].
///
/// [rng] makes the *shape* reproducible in tests while ids remain purely a
/// function of patient and timestamp, so tests can assert both determinism and
/// idempotency independently.
List<VitalsReading> generateSampleReadings({
  required String patientId,
  DateTime? end,
  Random? rng,
  int? hours,
}) {
  final random = rng ?? Random(patientId.hashCode);
  final slotSeconds = sampleSlot.inSeconds;

  // Snap to the grid exactly as the Python seeder does, so a device seeded
  // locally and the script seeded cohort land in the same time lattice.
  final anchor = end ?? DateTime.now().toUtc();
  final latestMs =
      anchor.millisecondsSinceEpoch ~/ (slotSeconds * 1000) * slotSeconds * 1000;

  final count = (hours ?? sampleWindow.inHours) * 60 ~/ sampleSlot.inMinutes;
  return [
    for (var i = count; i >= 1; i--)
      _readingAt(
        patientId,
        DateTime.fromMillisecondsSinceEpoch(
          latestMs - (i - 1) * slotSeconds * 1000,
          isUtc: true,
        ),
        random,
      ),
  ];
}

VitalsReading _readingAt(String patientId, DateTime at, Random rng) {
  // Circadian curve peaking mid-afternoon, dipping overnight — the shape a
  // worn watch actually records, and what the trend chart needs to render.
  final phase = sin((at.hour - 4) / 24 * 2 * pi);
  final drift = rng.nextDouble() * 2 - 1;

  return VitalsReading(
    heartRateBpm: (72 + drift * 4 + phase * 5).clamp(55, 110),
    spo2Pct: (97 + drift * 0.8).clamp(92, 100),
    ambientTempC: double.parse((28.5 + drift * 1.2 + phase * 0.8)
        .toStringAsFixed(2)),
    measuredAt: at,
    motionArtifact: rng.nextDouble() < 0.05,
  );
}
