/// Tests for the on-device archive.
///
/// Runs against a real in-memory SQLite database via `sqflite_common_ffi`'s
/// desktop binding, not a fake. The properties worth testing here — the sampling
/// exception for out-of-range readings, and that pruning never touches an
/// unsynced row — are properties of the SQL, so a mock store would test the mock.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/reading_store.dart';
import 'package:mecai_mobile/models/vitals.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

VitalsReading _reading({
  double? heartRate = 72,
  double? spo2 = 98,
  double? ambient = 28.5,
  double? bodyTemp,
  DateTime? at,
}) =>
    VitalsReading(
      heartRateBpm: heartRate,
      spo2Pct: spo2,
      ambientTempC: ambient,
      temperatureC: bodyTemp,
      measuredAt: at ?? DateTime.now().toUtc(),
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ReadingStore store;

  setUp(() async => store = await ReadingStore.openInMemory());
  tearDown(() async => store.close());

  group('client ids', () {
    test('are unique across many generations', () {
      final ids = {for (var i = 0; i < 2000; i++) generateClientId()};
      expect(ids.length, 2000);
    });

    test('carry the v4 version and variant markers', () {
      final id = generateClientId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
          r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('are long enough for the server to accept', () {
      // The API constrains client_id to 8..64 characters.
      expect(generateClientId().length, inInclusiveRange(8, 64));
    });
  });

  group('insert', () {
    test('stores a reading and returns its id', () async {
      final id = await store.insert(_reading());
      expect(id, isNotNull);
      expect(await store.totalCount(), 1);
    });

    test('round-trips every vital without loss', () async {
      // Relative to now, not a fixed date: `recent` selects against a rolling
      // window, and a hard-coded timestamp falls out of it a few days after the
      // test is written.
      final measuredAt = DateTime.now().toUtc();
      final original = VitalsReading(
        systolicMmHg: 128.5,
        diastolicMmHg: 82.0,
        heartRateBpm: 71.5,
        spo2Pct: 97.5,
        temperatureC: 36.85,
        ambientTempC: 29.25,
        measuredAt: measuredAt,
        motionArtifact: true,
      );
      await store.insert(original);

      final [restored] = await store.recent();
      expect(restored.systolicMmHg, 128.5);
      expect(restored.diastolicMmHg, 82.0);
      expect(restored.heartRateBpm, 71.5);
      expect(restored.spo2Pct, 97.5);
      expect(restored.temperatureC, 36.85);
      expect(restored.ambientTempC, 29.25);
      // The archive stores whole milliseconds, so compare at that resolution.
      expect(
        restored.measuredAt.millisecondsSinceEpoch,
        measuredAt.millisecondsSinceEpoch,
      );
      expect(restored.motionArtifact, isTrue);
    });

    test('keeps an absent vital absent rather than storing zero', () async {
      // The whole point of nullable vitals: the firmware has no cuff, and a chart
      // must not draw a cliff to zero for a sensor that does not exist.
      await store.insert(_reading());
      final [restored] = await store.recent();
      expect(restored.systolicMmHg, isNull);
      expect(restored.temperatureC, isNull);
      expect(restored.ambientTempC, isNotNull);
    });

    test('refuses a reading with no vitals at all', () async {
      // The server's schema rejects it, so storing one would create a row that
      // can never sync and would block the head of the oldest-first queue.
      final id = await store.insert(
        VitalsReading(measuredAt: DateTime.now().toUtc()),
      );
      expect(id, isNull);
      expect(await store.totalCount(), 0);
    });

    test('marks new readings unsynced', () async {
      await store.insert(_reading());
      expect(await store.pendingCount(), 1);
    });
  });

  group('sampling', () {
    test('persists the first reading', () {
      expect(store.shouldPersist(_reading()), isTrue);
    });

    test('skips a routine reading inside the sample window', () async {
      await store.insert(_reading());
      expect(store.shouldPersist(_reading()), isFalse);
    });

    test('persists again once the window has elapsed', () async {
      await store.insert(_reading());
      final later = DateTime.now().add(ReadingStore.sampleInterval);
      expect(store.shouldPersist(_reading(), now: later), isTrue);
    });

    test('always persists an out-of-range reading', () async {
      // The exception that matters. A sampling window is a bandwidth decision; it
      // must never be the reason the one hypoxic reading of the day is lost.
      await store.insert(_reading());
      expect(store.shouldPersist(_reading()), isFalse);
      expect(store.shouldPersist(_reading(spo2: 86)), isTrue);
    });

    test('insertSampled honours the window for routine readings', () async {
      expect(await store.insertSampled(_reading()), isNotNull);
      expect(await store.insertSampled(_reading()), isNull);
      expect(await store.totalCount(), 1);
    });

    test('insertSampled still writes a critical reading mid-window', () async {
      await store.insertSampled(_reading());
      expect(await store.insertSampled(_reading(spo2: 84)), isNotNull);
      expect(await store.totalCount(), 2);
    });

    test('a body-temperature fever also defeats the window', () async {
      await store.insertSampled(_reading());
      expect(await store.insertSampled(_reading(bodyTemp: 39.2)), isNotNull);
    });

    test('a warm room does not', () async {
      // ambient_temp_c must never produce a flag, so it must never force a write.
      await store.insertSampled(_reading());
      expect(await store.insertSampled(_reading(ambient: 34.0)), isNull);
    });
  });

  group('history', () {
    test('is returned oldest first', () async {
      final now = DateTime.now().toUtc();
      for (final minutes in [30, 10, 20]) {
        await store.insert(
          _reading(at: now.subtract(Duration(minutes: minutes)), heartRate: 60 + minutes.toDouble()),
        );
      }
      final history = await store.recent();
      expect(
        history.map((r) => r.heartRateBpm),
        [90.0, 80.0, 70.0],
      );
    });

    test('excludes readings outside the window', () async {
      final now = DateTime.now().toUtc();
      await store.insert(_reading(at: now.subtract(const Duration(hours: 40))));
      await store.insert(_reading(at: now.subtract(const Duration(minutes: 5))));

      expect((await store.recent(window: const Duration(hours: 24))).length, 1);
      expect((await store.recent(window: const Duration(days: 7))).length, 2);
    });

    test('a limit keeps the most recent readings, not the oldest', () async {
      final now = DateTime.now().toUtc();
      for (var i = 10; i >= 1; i--) {
        await store.insert(
          _reading(at: now.subtract(Duration(minutes: i)), heartRate: 60 + i.toDouble()),
        );
      }
      final history = await store.recent(limit: 3);
      // Charting the oldest rows would pin the graph to the first minutes of
      // monitoring and never move again.
      expect(history.map((r) => r.heartRateBpm), [63.0, 62.0, 61.0]);
    });

    test('reports the newest measurement time', () async {
      final now = DateTime.now().toUtc();
      await store.insert(_reading(at: now.subtract(const Duration(hours: 2))));
      await store.insert(_reading(at: now.subtract(const Duration(minutes: 1))));

      final last = await store.lastMeasuredAt();
      expect(now.difference(last!).inMinutes, lessThanOrEqualTo(1));
    });
  });

  group('sync bookkeeping', () {
    test('unsynced drains oldest first', () async {
      final now = DateTime.now().toUtc();
      await store.insert(_reading(at: now, heartRate: 80));
      await store.insert(
        _reading(at: now.subtract(const Duration(hours: 1)), heartRate: 70),
      );

      final queued = await store.unsynced();
      // A backlog should arrive as a coherent history, not newest-first with
      // gaps that fill in later.
      expect(queued.first.reading.heartRateBpm, 70.0);
    });

    test('is capped at the batch size', () async {
      final now = DateTime.now().toUtc();
      for (var i = 0; i < ReadingStore.syncBatchSize + 25; i++) {
        await store.insert(_reading(at: now.subtract(Duration(minutes: i))));
      }
      expect((await store.unsynced()).length, ReadingStore.syncBatchSize);
    });

    test('markSynced clears the pending count', () async {
      await store.insert(_reading());
      final queued = await store.unsynced();
      await store.markSynced(queued.map((r) => r.clientId));

      expect(await store.pendingCount(), 0);
      expect(await store.totalCount(), 1);
    });

    test('markSynced with no ids is a no-op', () async {
      await store.insert(_reading());
      await store.markSynced(const []);
      expect(await store.pendingCount(), 1);
    });

    test('history still includes synced readings', () async {
      // Uploading is a backup, not a handover. The phone keeps its copy.
      await store.insert(_reading());
      await store.markSynced((await store.unsynced()).map((r) => r.clientId));
      expect((await store.recent()).length, 1);
    });

    test('a repeatedly refused reading stops blocking the queue', () async {
      // Without this, one row the server will never accept sits at the head of
      // the oldest-first queue and starves every reading behind it.
      final now = DateTime.now().toUtc();
      await store.insert(
        _reading(at: now.subtract(const Duration(hours: 1)), heartRate: 70),
      );
      await store.insert(_reading(at: now, heartRate: 80));

      final poison = (await store.unsynced()).first.clientId;
      for (var attempt = 0; attempt < ReadingStore.maxSyncAttempts; attempt++) {
        await store.recordFailedAttempt([poison]);
      }

      final queued = await store.unsynced();
      expect(queued.map((r) => r.clientId), isNot(contains(poison)));
      expect(queued.first.reading.heartRateBpm, 80.0);
    });

    test('a quarantined reading is counted, not silently dropped', () async {
      await store.insert(_reading());
      final id = (await store.unsynced()).first.clientId;
      for (var attempt = 0; attempt < ReadingStore.maxSyncAttempts; attempt++) {
        await store.recordFailedAttempt([id]);
      }

      expect(await store.pendingCount(), 0);
      expect(await store.quarantinedCount(), 1);
      // Still on the phone — the user is told the backup is incomplete rather
      // than having the data disappear.
      expect(await store.totalCount(), 1);
    });

    test('a reading below the attempt ceiling is still retried', () async {
      await store.insert(_reading());
      final id = (await store.unsynced()).first.clientId;
      await store.recordFailedAttempt([id]);

      expect((await store.unsynced()).length, 1);
      expect(await store.quarantinedCount(), 0);
    });

    test('sync payload carries the client id alongside the vitals', () async {
      await store.insert(_reading());
      final json = (await store.unsynced()).first.toSyncJson();

      expect(json['client_id'], isNotNull);
      expect(json['heart_rate_bpm'], 72.0);
      expect(json['measured_at'], isA<String>());
    });
  });

  group('SOS', () {
    test('is queued with the vitals from the moment of the press', () async {
      await store.insertSos(
        triggeredAt: DateTime.now().toUtc(),
        source: 'app',
        reading: _reading(heartRate: 118, spo2: 89),
      );

      final [event] = await store.unsyncedSos();
      expect(event.heartRateBpm, 118.0);
      expect(event.spo2Pct, 89.0);
      expect(event.source, 'app');
    });

    test('never uploads ambient temperature as a body reading', () async {
      // A responder seeing 28 C would read profound hypothermia in a warm room.
      await store.insertSos(
        triggeredAt: DateTime.now().toUtc(),
        source: 'watch',
        reading: _reading(ambient: 28.5),
      );

      final [event] = await store.unsyncedSos();
      expect(event.temperatureC, isNull);
    });

    test('is recorded without a location fix', () async {
      await store.insertSos(
        triggeredAt: DateTime.now().toUtc(),
        source: 'app',
      );

      final [event] = await store.unsyncedSos();
      expect(event.latitude, isNull);
      expect(await store.pendingSosCount(), 1);
    });

    test('marking it synced clears the queue', () async {
      await store.insertSos(triggeredAt: DateTime.now().toUtc(), source: 'app');
      await store.markSosSynced((await store.unsyncedSos()).map((e) => e.clientId));
      expect(await store.pendingSosCount(), 0);
    });

    test('sync payload names the patient it belongs to', () async {
      await store.insertSos(triggeredAt: DateTime.now().toUtc(), source: 'app');
      final json = (await store.unsyncedSos()).first.toSyncJson('patient-123456');
      expect(json['patient_id'], 'patient-123456');
      expect(json['source'], 'app');
    });
  });

  group('retention', () {
    test('drops synced readings past the window', () async {
      final now = DateTime.now().toUtc();
      await store.insert(_reading(at: now.subtract(const Duration(days: 200))));
      await store.markSynced((await store.unsynced()).map((r) => r.clientId));

      expect(await store.prune(olderThanDays: 90), 1);
      expect(await store.totalCount(), 0);
    });

    test('never drops an unsynced reading, however old', () async {
      // It is the only copy in existence. An unreachable server for longer than
      // the retention window must not delete the data it was meant to receive.
      final now = DateTime.now().toUtc();
      await store.insert(_reading(at: now.subtract(const Duration(days: 200))));

      expect(await store.prune(olderThanDays: 90), 0);
      expect(await store.totalCount(), 1);
    });

    test('leaves recent readings alone', () async {
      await store.insert(_reading());
      await store.markSynced((await store.unsynced()).map((r) => r.clientId));
      expect(await store.prune(olderThanDays: 90), 0);
    });

    test('never prunes SOS events', () async {
      await store.insertSos(
        triggeredAt: DateTime.now().toUtc().subtract(const Duration(days: 400)),
        source: 'app',
      );
      await store.prune(olderThanDays: 1);
      expect(await store.pendingSosCount(), 1);
    });

    test('deleteAll clears readings and SOS events', () async {
      await store.insert(_reading());
      await store.insertSos(triggeredAt: DateTime.now().toUtc(), source: 'app');

      await store.deleteAll();

      expect(await store.totalCount(), 0);
      expect(await store.pendingSosCount(), 0);
      // The sampling clock resets too, so the next reading is archived
      // immediately rather than being skipped by a stale window.
      expect(store.shouldPersist(_reading()), isTrue);
    });
  });

  group('daily stats', () {
    /// The body-temperature estimate on the Trends day summary is anchored to the
    /// worn-only case average. The whole-day average is a different figure and the
    /// two must not be conflated: a partly-worn hot day would otherwise report a
    /// body temperature pulled toward the weather.
    test('separates the worn case average from the whole-day one', () async {
      final day = DateTime.now();

      // Worn: on the wrist, case sitting warm.
      for (var i = 0; i < 4; i++) {
        await store.insert(
          _reading(ambient: 33, at: day.toUtc().subtract(Duration(minutes: i))),
          wearing: true,
        );
      }
      // Off the wrist on a hot afternoon — the sensor is a room thermometer here.
      for (var i = 4; i < 8; i++) {
        await store.insert(
          _reading(ambient: 31, at: day.toUtc().subtract(Duration(minutes: i))),
          wearing: false,
        );
      }

      final stats = await store.dailyStats(from: day, to: day);
      final entry = stats[DateTime(day.year, day.month, day.day)]!;

      expect(entry.ambientWornAvg, closeTo(33, 0.001));
      expect(entry.ambientAvg, closeTo(32, 0.001));
    });

    test('a day with no worn readings has no worn average', () async {
      final day = DateTime.now();
      await store.insert(_reading(ambient: 31, at: day.toUtc()), wearing: false);

      final stats = await store.dailyStats(from: day, to: day);
      final entry = stats[DateTime(day.year, day.month, day.day)]!;

      // Null is what the summary reads as "no body estimate for this day".
      expect(entry.ambientWornAvg, isNull);
      expect(entry.ambientAvg, closeTo(31, 0.001));
    });

    test('firmware that never reports contact has no worn average', () async {
      final day = DateTime.now();
      await store.insert(_reading(ambient: 30, at: day.toUtc()));

      final stats = await store.dailyStats(from: day, to: day);
      final entry = stats[DateTime(day.year, day.month, day.day)]!;

      expect(entry.ambientWornAvg, isNull);
      expect(entry.wornCount, 0);
    });
  });
}
