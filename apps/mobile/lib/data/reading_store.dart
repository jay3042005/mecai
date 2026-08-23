/// On-device readings archive.
///
/// The phone is the **system of record** until a reading is acknowledged by the
/// server. BLE data arrives whether or not there is a network, and before this
/// existed every reading lived in a `List` in widget state — so closing the app
/// discarded the entire history, and a patient who had been monitored for a week
/// opened it to an empty chart.
///
/// ### Sampling, and the exception that matters
///
/// The watch notifies at 2 Hz. Persisting every packet is 172,800 rows a day for
/// data that changes on the scale of minutes, so [shouldPersist] samples at
/// [sampleInterval].
///
/// **An out-of-range reading is written immediately regardless.** A sampling
/// window that happens to skip the one reading where SpO2 hit 86% would discard
/// the single most clinically important measurement of the day in order to save a
/// row of storage. Sampling is a bandwidth decision; it must never be an
/// alerting decision.
///
/// ### Why client_id is the primary key
///
/// It is generated here, and it is what makes re-syncing safe. A phone on a rural
/// network loses the connection mid-batch and retries; the server's
/// `(patient_id, client_id)` uniqueness turns the retry into a no-op instead of
/// duplicating rows that would be indistinguishable from real rapid measurements
/// in a trend chart.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/vitals.dart';
import 'acute_flags.dart';

/// One archived reading: the measurement plus its backup state.
@immutable
class StoredReading {
  const StoredReading({
    required this.clientId,
    required this.reading,
    required this.synced,
  });

  final String clientId;
  final VitalsReading reading;
  final bool synced;

  /// The wire shape `POST /v1/readings/sync` expects.
  Map<String, dynamic> toSyncJson() => <String, dynamic>{
        ...reading.toJson(),
        'client_id': clientId,
      };
}

/// A queued SOS press awaiting upload.
@immutable
class StoredSos {
  const StoredSos({
    required this.clientId,
    required this.triggeredAt,
    required this.source,
    this.latitude,
    this.longitude,
    this.accuracyM,
    this.heartRateBpm,
    this.spo2Pct,
    this.temperatureC,
    this.note,
    this.synced = false,
  });

  final String clientId;
  final DateTime triggeredAt;
  final String source;
  final double? latitude;
  final double? longitude;
  final double? accuracyM;
  final double? heartRateBpm;
  final double? spo2Pct;
  final double? temperatureC;
  final String? note;
  final bool synced;

  Map<String, dynamic> toSyncJson(String patientId) => <String, dynamic>{
        'patient_id': patientId,
        'client_id': clientId,
        'triggered_at': triggeredAt.toUtc().toIso8601String(),
        'source': source,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_m': accuracyM,
        'heart_rate_bpm': heartRateBpm,
        'spo2_pct': spo2Pct,
        'temperature_c': temperatureC,
        'note': note,
      };
}

/// RFC 4122 version 4, from the platform's secure generator.
///
/// A dedicated `uuid` dependency would add a package to produce sixteen random
/// bytes. The variant and version bits are set because the server validates the
/// field as an opaque string of bounded length, and a malformed id that still
/// happens to be unique would work — but would be a needless surprise to anyone
/// reading the archive later.
String generateClientId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

class ReadingStore {
  ReadingStore._(this._db);

  final Database _db;

  static const _fileName = 'mecai_readings.db';
  static const _schemaVersion = 2;

  /// How often a routine reading is archived.
  ///
  /// The watch streams at 2 Hz, so an unsampled archive would grow by ~173k rows
  /// a day to describe data that moves over minutes. Thirty seconds keeps that to
  /// ~2,880 rows a day — a few megabytes over the full retention window, and
  /// enough resolution that an hour-scale chart shows shape rather than a
  /// straight line between two distant points.
  static const Duration sampleInterval = Duration(seconds: 30);

  /// Rows older than this are dropped by [prune]. RA 10173 requires a stated
  /// retention period, and an unbounded archive on a phone eventually is one.
  static const int retentionDays = 90;

  /// Ceiling on one upload batch. Matches the server's `max_length=500` on
  /// `SyncRequest.readings` — a larger batch would be rejected wholesale, so a
  /// backlog built up over a week of no signal would never drain.
  static const int syncBatchSize = 200;

  /// Upload attempts before a reading is set aside.
  ///
  /// The queue drains oldest-first, so one row the server refuses — a schema
  /// change, a value that fails validation — would block every reading behind it
  /// indefinitely. After this many failures it stops being retried and is counted
  /// by [quarantinedCount] instead, which Settings shows: data the server would
  /// not take is something the user should be told about, not something to hide
  /// by silently dropping it.
  ///
  /// Transient failures never reach this — an unreachable server increments
  /// nothing, because that is not the reading's fault.
  static const int maxSyncAttempts = 5;

  static Future<ReadingStore> open({String? path}) async {
    final dbPath = path ?? p.join(await getDatabasesPath(), _fileName);
    final db = await openDatabase(
      dbPath,
      version: _schemaVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      // An existing archive is migrated, never recreated. Dropping and rebuilding
      // would discard readings that have not been backed up yet — the only copy
      // in existence.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE readings ADD COLUMN wearing INTEGER');
        }
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE readings (
            client_id       TEXT PRIMARY KEY,
            systolic_mmhg   REAL,
            diastolic_mmhg  REAL,
            heart_rate_bpm  REAL,
            spo2_pct        REAL,
            temperature_c   REAL,
            ambient_temp_c  REAL,
            measured_at     INTEGER NOT NULL,
            motion_artifact INTEGER NOT NULL DEFAULT 0,

            -- Whether the watch reported skin contact for this reading.
            --
            -- Not sent to the server (its schema has no field for it) but kept
            -- locally so analytics can tell "no data because the watch was off"
            -- from "no data because the phone was offline". Without it a day the
            -- user simply did not wear the device is indistinguishable from a
            -- day the sync failed, and only one of those needs action.
            wearing         INTEGER,

            synced          INTEGER NOT NULL DEFAULT 0,
            synced_at       INTEGER,
            -- Failed upload attempts. A row the server will never accept would
            -- otherwise sit at the head of the oldest-first queue and block every
            -- reading behind it, forever. See [maxSyncAttempts].
            sync_attempts   INTEGER NOT NULL DEFAULT 0
          )
        ''');
        // Sorted history and the unsynced-backlog scan are the only two queries
        // that run often, so they get the two indexes.
        await db.execute(
          'CREATE INDEX idx_readings_measured_at ON readings (measured_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_readings_synced '
          'ON readings (synced, sync_attempts, measured_at)',
        );
        await db.execute('''
          CREATE TABLE sos_events (
            client_id      TEXT PRIMARY KEY,
            triggered_at   INTEGER NOT NULL,
            source         TEXT NOT NULL,
            latitude       REAL,
            longitude      REAL,
            accuracy_m     REAL,
            heart_rate_bpm REAL,
            spo2_pct       REAL,
            temperature_c  REAL,
            note           TEXT,
            synced         INTEGER NOT NULL DEFAULT 0,
            synced_at      INTEGER
          )
        ''');
      },
    );
    return ReadingStore._(db);
  }

  /// In-memory store for tests. Never touches the platform databases directory.
  static Future<ReadingStore> openInMemory() => open(path: inMemoryDatabasePath);

  Future<void> close() => _db.close();

  // ─────────────────────────── sampling ───────────────────────────

  DateTime? _lastPersistedAt;

  /// Whether [reading] should be archived now.
  ///
  /// True when the sample interval has elapsed, when nothing has been archived
  /// yet, **or when the reading carries an acute flag** — see the class docstring
  /// on why the last case is not optional.
  bool shouldPersist(VitalsReading reading, {DateTime? now}) {
    if (evaluateAcuteFlags(reading).isNotEmpty) return true;
    final last = _lastPersistedAt;
    if (last == null) return true;
    return (now ?? DateTime.now()).difference(last) >= sampleInterval;
  }

  // ──────────────────────────── writes ────────────────────────────

  /// Archives a reading and returns its id.
  ///
  /// [clientId] overrides the generated one. Sample data uses it to derive ids
  /// from the reading's timestamp, so regenerating the same history is
  /// idempotent on the server instead of doubling every trend line — the same
  /// rule `scripts/seed-demo.py` follows.
  ///
  /// A reading with no vitals at all is dropped: the server's schema rejects it,
  /// so storing one would create a row that can never sync and would sit at the
  /// head of the backlog queue forever, blocking everything behind it.
  Future<String?> insert(
    VitalsReading reading, {
    bool? wearing,
    String? clientId,
  }) async {
    if (!_hasAnyVital(reading)) return null;

    final id = clientId ?? generateClientId();
    await _db.insert('readings', {
      'client_id': id,
      'systolic_mmhg': reading.systolicMmHg,
      'diastolic_mmhg': reading.diastolicMmHg,
      'heart_rate_bpm': reading.heartRateBpm,
      'spo2_pct': reading.spo2Pct,
      'temperature_c': reading.temperatureC,
      'ambient_temp_c': reading.ambientTempC,
      'measured_at': reading.measuredAt.toUtc().millisecondsSinceEpoch,
      'motion_artifact': reading.motionArtifact ? 1 : 0,
      'wearing': wearing == null ? null : (wearing ? 1 : 0),
      'synced': 0,
    });
    _lastPersistedAt = DateTime.now();
    return id;
  }

  /// [insert], but only when [shouldPersist] agrees. Returns the id if written.
  Future<String?> insertSampled(VitalsReading reading, {bool? wearing}) async {
    if (!shouldPersist(reading)) return null;
    return insert(reading, wearing: wearing);
  }

  static bool _hasAnyVital(VitalsReading r) =>
      r.systolicMmHg != null ||
      r.diastolicMmHg != null ||
      r.heartRateBpm != null ||
      r.spo2Pct != null ||
      r.temperatureC != null ||
      r.ambientTempC != null;

  /// Counts a rejection against the given readings.
  ///
  /// Called only for a response the server actually returned — a 4xx means these
  /// rows are the problem. A network failure must not increment anything, or a
  /// fortnight in a dead-signal area would quarantine a patient's entire history
  /// for a fault that was never theirs.
  Future<void> recordFailedAttempt(Iterable<String> clientIds) async {
    final ids = clientIds.toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE readings SET sync_attempts = sync_attempts + 1 '
      'WHERE client_id IN ($placeholders)',
      ids,
    );
  }

  Future<void> markSynced(Iterable<String> clientIds) async {
    final ids = clientIds.toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE readings SET synced = 1, synced_at = ? '
      'WHERE client_id IN ($placeholders)',
      [DateTime.now().toUtc().millisecondsSinceEpoch, ...ids],
    );
  }

  // ──────────────────────────── reads ─────────────────────────────

  /// Recent history, oldest first — the order the charts plot.
  ///
  /// Selected newest-first under the limit and then reversed, so a long window
  /// returns the most recent [limit] rows. Selecting oldest-first would pin the
  /// charts to the patient's first hour of data forever.
  Future<List<VitalsReading>> recent({
    Duration window = const Duration(hours: 24),
    int limit = 500,
  }) async {
    final cutoff =
        DateTime.now().toUtc().subtract(window).millisecondsSinceEpoch;
    final rows = await _db.query(
      'readings',
      where: 'measured_at >= ?',
      whereArgs: [cutoff],
      orderBy: 'measured_at DESC',
      limit: limit,
    );
    return rows.reversed.map(_toReading).toList(growable: false);
  }

  /// The oldest unsynced readings, capped at [syncBatchSize].
  ///
  /// Oldest first on purpose: a backlog drains in the order it accumulated, so a
  /// week of offline readings arrives as a coherent history rather than newest
  /// rows interleaved with gaps that fill in later.
  Future<List<StoredReading>> unsynced({int? limit}) async {
    final rows = await _db.query(
      'readings',
      where: 'synced = 0 AND sync_attempts < ?',
      whereArgs: [maxSyncAttempts],
      orderBy: 'measured_at ASC',
      limit: limit ?? syncBatchSize,
    );
    return rows
        .map((row) => StoredReading(
              clientId: row['client_id'] as String,
              reading: _toReading(row),
              synced: false,
            ))
        .toList(growable: false);
  }

  /// Readings still queued for upload and still being retried.
  Future<int> pendingCount() async =>
      _count('readings', 'synced = 0 AND sync_attempts < $maxSyncAttempts');

  /// Readings the server refused [maxSyncAttempts] times, no longer retried.
  ///
  /// Surfaced rather than swallowed: a non-zero count here means readings exist
  /// on this phone that will never reach the archive, and the user is entitled to
  /// know that their backup is incomplete.
  Future<int> quarantinedCount() async =>
      _count('readings', 'synced = 0 AND sync_attempts >= $maxSyncAttempts');

  Future<int> totalCount() async => _count('readings', null);

  Future<DateTime?> lastMeasuredAt() async {
    final rows = await _db.rawQuery('SELECT MAX(measured_at) AS t FROM readings');
    final value = rows.first['t'] as int?;
    return value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  Future<int> _count(String table, String? where) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM $table${where == null ? '' : ' WHERE $where'}',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  static VitalsReading _toReading(Map<String, Object?> row) => VitalsReading(
        systolicMmHg: (row['systolic_mmhg'] as num?)?.toDouble(),
        diastolicMmHg: (row['diastolic_mmhg'] as num?)?.toDouble(),
        heartRateBpm: (row['heart_rate_bpm'] as num?)?.toDouble(),
        spo2Pct: (row['spo2_pct'] as num?)?.toDouble(),
        temperatureC: (row['temperature_c'] as num?)?.toDouble(),
        ambientTempC: (row['ambient_temp_c'] as num?)?.toDouble(),
        measuredAt: DateTime.fromMillisecondsSinceEpoch(
          row['measured_at'] as int,
          isUtc: true,
        ),
        motionArtifact: (row['motion_artifact'] as int? ?? 0) != 0,
      );

  // ─────────────────────────── analytics ──────────────────────────

  /// One day's summary for a single vital.
  ///
  /// Aggregated in SQL rather than by loading a day of rows into Dart: a day holds
  /// ~2,880 readings, and the calendar asks for a month at a time. Pulling 86,000
  /// rows across the platform channel to compute six numbers would make opening
  /// the calendar visibly slow.
  Future<Map<DateTime, DayStats>> dailyStats({
    required DateTime from,
    required DateTime to,
  }) async {
    // Grouped by *local* calendar day, because that is the day the user lived.
    // Grouping by UTC would split a Philippine evening across two rows — readings
    // after 08:00 local fall into the next UTC date (UTC+8).
    final rows = await _db.rawQuery(
      """
      SELECT
        CAST(strftime('%Y', measured_at / 1000, 'unixepoch', 'localtime') AS INTEGER) AS y,
        CAST(strftime('%m', measured_at / 1000, 'unixepoch', 'localtime') AS INTEGER) AS m,
        CAST(strftime('%d', measured_at / 1000, 'unixepoch', 'localtime') AS INTEGER) AS d,
        COUNT(*)              AS n,
        AVG(heart_rate_bpm)   AS hr_avg,
        MIN(heart_rate_bpm)   AS hr_min,
        MAX(heart_rate_bpm)   AS hr_max,
        AVG(spo2_pct)         AS spo2_avg,
        MIN(spo2_pct)         AS spo2_min,
        AVG(ambient_temp_c)   AS ambient_avg,
        AVG(CASE WHEN wearing = 1 THEN ambient_temp_c END) AS ambient_worn_avg,
        MAX(temperature_c)    AS body_max,
        SUM(CASE WHEN wearing = 1 THEN 1 ELSE 0 END) AS worn
      FROM readings
      WHERE measured_at >= ? AND measured_at < ?
      GROUP BY y, m, d
      """,
      [
        _startOfDay(from).millisecondsSinceEpoch,
        _startOfDay(to).add(const Duration(days: 1)).millisecondsSinceEpoch,
      ],
    );

    return {
      for (final row in rows)
        DateTime(row['y'] as int, row['m'] as int, row['d'] as int): DayStats(
          day: DateTime(row['y'] as int, row['m'] as int, row['d'] as int),
          readingCount: (row['n'] as int?) ?? 0,
          heartRateAvg: (row['hr_avg'] as num?)?.toDouble(),
          heartRateMin: (row['hr_min'] as num?)?.toDouble(),
          heartRateMax: (row['hr_max'] as num?)?.toDouble(),
          spo2Avg: (row['spo2_avg'] as num?)?.toDouble(),
          spo2Min: (row['spo2_min'] as num?)?.toDouble(),
          ambientAvg: (row['ambient_avg'] as num?)?.toDouble(),
          ambientWornAvg: (row['ambient_worn_avg'] as num?)?.toDouble(),
          bodyTempMax: (row['body_max'] as num?)?.toDouble(),
          wornCount: (row['worn'] as int?) ?? 0,
        ),
    };
  }

  /// Every reading on one local calendar day, oldest first.
  ///
  /// Down-sampled to at most [maxPoints] by taking every Nth row. A day holds
  /// ~2,880 readings and a phone chart is a few hundred pixels wide, so plotting
  /// all of them costs time to draw marks narrower than a pixel.
  Future<List<VitalsReading>> readingsForDay(
    DateTime day, {
    int maxPoints = 480,
  }) async {
    final start = _startOfDay(day);
    final rows = await _db.query(
      'readings',
      where: 'measured_at >= ? AND measured_at < ?',
      whereArgs: [
        start.millisecondsSinceEpoch,
        start.add(const Duration(days: 1)).millisecondsSinceEpoch,
      ],
      orderBy: 'measured_at ASC',
    );

    if (rows.length <= maxPoints) {
      return rows.map(_toReading).toList(growable: false);
    }

    // Even stride, and the last row is always kept: the most recent reading of
    // the day is the one a reader looks for, and a stride that happens to skip it
    // would make the chart end early for no visible reason.
    final stride = (rows.length / maxPoints).ceil();
    final sampled = <VitalsReading>[
      for (var i = 0; i < rows.length; i += stride) _toReading(rows[i]),
    ];
    final last = _toReading(rows.last);
    if (sampled.isEmpty || sampled.last.measuredAt != last.measuredAt) {
      sampled.add(last);
    }
    return sampled;
  }

  /// Local calendar days that hold at least one reading, for the calendar's dots.
  Future<Set<DateTime>> daysWithReadings({
    required DateTime from,
    required DateTime to,
  }) async {
    final stats = await dailyStats(from: from, to: to);
    return stats.keys.toSet();
  }

  /// Midnight local on [value]'s calendar day.
  static DateTime _startOfDay(DateTime value) {
    final local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  // ───────────────────────────── SOS ──────────────────────────────

  /// Queues an SOS press for upload.
  ///
  /// Written locally first, exactly like a reading. An SOS raised where there is
  /// no signal is still an SOS, and the alert has to survive until the phone can
  /// deliver it rather than being lost at the moment of the failed request.
  Future<String> insertSos({
    required DateTime triggeredAt,
    required String source,
    double? latitude,
    double? longitude,
    double? accuracyM,
    VitalsReading? reading,
    String? note,
  }) async {
    final clientId = generateClientId();
    await _db.insert('sos_events', {
      'client_id': clientId,
      'triggered_at': triggeredAt.toUtc().millisecondsSinceEpoch,
      'source': source,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy_m': accuracyM,
      'heart_rate_bpm': reading?.heartRateBpm,
      'spo2_pct': reading?.spo2Pct,
      // Body temperature only. Ambient must not be uploaded as a body reading —
      // a responder reading 28 C would see profound hypothermia in a warm room.
      'temperature_c': reading?.temperatureC,
      'note': note,
      'synced': 0,
    });
    return clientId;
  }

  Future<List<StoredSos>> unsyncedSos({int limit = 20}) async {
    final rows = await _db.query(
      'sos_events',
      where: 'synced = 0',
      orderBy: 'triggered_at ASC',
      limit: limit,
    );
    return rows
        .map((row) => StoredSos(
              clientId: row['client_id'] as String,
              triggeredAt: DateTime.fromMillisecondsSinceEpoch(
                row['triggered_at'] as int,
                isUtc: true,
              ),
              source: row['source'] as String,
              latitude: (row['latitude'] as num?)?.toDouble(),
              longitude: (row['longitude'] as num?)?.toDouble(),
              accuracyM: (row['accuracy_m'] as num?)?.toDouble(),
              heartRateBpm: (row['heart_rate_bpm'] as num?)?.toDouble(),
              spo2Pct: (row['spo2_pct'] as num?)?.toDouble(),
              temperatureC: (row['temperature_c'] as num?)?.toDouble(),
              note: row['note'] as String?,
            ))
        .toList(growable: false);
  }

  Future<void> markSosSynced(Iterable<String> clientIds) async {
    final ids = clientIds.toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE sos_events SET synced = 1, synced_at = ? '
      'WHERE client_id IN ($placeholders)',
      [DateTime.now().toUtc().millisecondsSinceEpoch, ...ids],
    );
  }

  Future<int> pendingSosCount() async => _count('sos_events', 'synced = 0');

  // ─────────────────────────── retention ──────────────────────────

  /// Drops readings past the retention window.
  ///
  /// **Only synced rows.** An unsynced reading is the sole copy in existence; an
  /// unreachable server for longer than the window must not silently delete the
  /// data it was supposed to receive. SOS events are never pruned.
  Future<int> prune({int? olderThanDays}) async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: olderThanDays ?? retentionDays))
        .millisecondsSinceEpoch;
    return _db.delete(
      'readings',
      where: 'measured_at < ? AND synced = 1',
      whereArgs: [cutoff],
    );
  }

  /// Wipes the archive. Wired to the "Delete local data" control in Settings,
  /// which RA 10173's consent model needs to be an action the user can take.
  Future<void> deleteAll() async {
    await _db.delete('readings');
    await _db.delete('sos_events');
    _lastPersistedAt = null;
  }
}

/// One local calendar day's aggregates, as computed by [ReadingStore.dailyStats].
///
/// Every field is nullable because the device measures incrementally: a day of
/// readings from the current firmware has heart rate, SpO2 and ambient air, and
/// nothing for body temperature or blood pressure. Null means "not measured",
/// which the UI renders as an em-dash — never as zero.
@immutable
class DayStats {
  const DayStats({
    required this.day,
    required this.readingCount,
    this.heartRateAvg,
    this.heartRateMin,
    this.heartRateMax,
    this.spo2Avg,
    this.spo2Min,
    this.ambientAvg,
    this.ambientWornAvg,
    this.bodyTempMax,
    this.wornCount = 0,
  });

  final DateTime day;
  final int readingCount;
  final double? heartRateAvg;
  final double? heartRateMin;
  final double? heartRateMax;

  final double? spo2Avg;

  /// The day's *lowest* SpO2, not its average.
  ///
  /// A day averaging 97% with a single dip to 86% is the day worth looking at,
  /// and the average hides exactly that. For oxygen the extreme is the clinically
  /// interesting figure, so the calendar ranks days by this.
  final double? spo2Min;

  final double? ambientAvg;

  /// The case average over **worn readings only**.
  ///
  /// Separate from [ambientAvg] because the body-temperature estimate is only
  /// meaningful for readings taken on the wrist: off it, the sensor is a room
  /// thermometer, and averaging a worn morning with an unworn afternoon on a
  /// 31 °C day pulls the figure toward the weather. Null when the day has no worn
  /// readings, which is the signal that no body estimate can be offered for it.
  ///
  /// [ambientAvg] is still the right figure for the raw case reading itself, which
  /// is a property of the device rather than of the wearer.
  final double? ambientWornAvg;

  final double? bodyTempMax;

  /// Readings where the watch reported skin contact.
  final int wornCount;

  /// Whether the watch was in contact for most of the day's readings.
  ///
  /// Distinguishes a quiet day from an unworn one. Null when the firmware did not
  /// report contact at all, so the UI can stay silent rather than claim the watch
  /// was off.
  bool? get mostlyWorn =>
      readingCount == 0 ? null : (wornCount == 0 ? null : wornCount * 2 >= readingCount);
}
