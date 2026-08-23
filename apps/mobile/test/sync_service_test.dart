/// Tests for the backup path.
///
/// The behaviours pinned here are the ones a rural network exercises constantly,
/// and each one is a decision that could reasonably have gone the other way:
///
/// * A dead network costs the queue nothing — no attempt is counted, because the
///   reading is not at fault.
/// * A server refusal *does* count, so one unacceptable row cannot block the
///   backlog behind it forever.
/// * Duplicates are success — the server already holds them.
/// * A 5xx is transient, not a refusal. A restarting server must not burn
///   attempts against good readings.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mecai_mobile/data/profile_store.dart';
import 'package:mecai_mobile/data/reading_store.dart';
import 'package:mecai_mobile/data/settings.dart';
import 'package:mecai_mobile/data/sync_service.dart';
import 'package:mecai_mobile/models/vitals.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Records what the phone actually sent, so the tests can assert on the wire.
class _Recorder {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  void call(http.Request request) {
    paths.add(request.url.path);
    bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
  }

  Iterable<Map<String, dynamic>> bodiesFor(String path) {
    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < paths.length; i++) {
      if (paths[i] == path) result.add(bodies[i]);
    }
    return result;
  }

  int countFor(String path) => paths.where((p) => p == path).length;
}

VitalsReading _reading({double spo2 = 98, DateTime? at}) => VitalsReading(
      heartRateBpm: 72,
      spo2Pct: spo2,
      ambientTempC: 28.5,
      measuredAt: at ?? DateTime.now().toUtc(),
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late ReadingStore store;
  late AppSettings settings;
  late ProfileStore profiles;
  late _Recorder recorder;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await ReadingStore.openInMemory();
    settings = await AppSettings.load();
    profiles = await ProfileStore.load(null);
    recorder = _Recorder();
  });

  tearDown(() async => store.close());

  /// A service whose HTTP calls are answered by [respond].
  SyncService serviceWith(
    http.Response Function(http.Request request) respond,
  ) =>
      SyncService(
        settings: settings,
        profileStore: profiles,
        store: store,
        client: MockClient((request) async {
          recorder.call(request);
          return respond(request);
        }),
      );

  http.Response okResponse(http.Request request) {
    if (request.url.path == '/v1/readings/sync') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final readings = body['readings'] as List<dynamic>;
      return http.Response(
        jsonEncode({
          'patient_id': body['patient_id'],
          'stored': readings.length,
          'duplicates': 0,
          'rejected': <String>[],
          'server_time': DateTime.now().toUtc().toIso8601String(),
        }),
        200,
      );
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  }

  group('happy path', () {
    test('enrols before uploading readings', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.syncNow();

      // Enrolment creates the patient record; a sync that arrived first would
      // depend on the server's fallback rather than the intended order.
      expect(recorder.paths.first, '/v1/patients');
      expect(recorder.paths, contains('/v1/readings/sync'));
      service.dispose();
    });

    test('sends the locally-minted patient id', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.syncNow();

      final enrolment = recorder.bodiesFor('/v1/patients').single;
      expect(enrolment['patient_id'], settings.patientId);
      expect(settings.patientId.length, greaterThanOrEqualTo(8));
      service.dispose();
    });

    test('falls back to a device-derived display name', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.syncNow();

      // A blank roster row is worse than a pseudonymous one — a clinician cannot
      // act on a patient they cannot identify.
      final name = recorder.bodiesFor('/v1/patients').single['display_name'] as String;
      expect(name, startsWith('Patient '));
      expect(name.trim(), isNotEmpty);
      service.dispose();
    });

    test('sends the name once the user has entered one', () async {
      await profiles.setDisplayName('R. Bautista');
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.syncNow();

      expect(
        recorder.bodiesFor('/v1/patients').single['display_name'],
        'R. Bautista',
      );
      service.dispose();
    });

    test('marks uploaded readings as synced', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      final outcome = await service.syncNow();

      expect(outcome.stored, 1);
      expect(outcome.state, SyncState.upToDate);
      expect(await store.pendingCount(), 0);
      service.dispose();
    });

    test('records the sync time so Settings can report it', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      expect(settings.lastSyncAt, isNull);
      await service.syncNow();
      expect(settings.lastSyncAt, isNotNull);
      service.dispose();
    });

    test('carries the profile with the batch', () async {
      // So a questionnaire edited offline scores the readings it arrives with,
      // rather than whatever the server last heard.
      await profiles.save(
        ProfileStore.empty.copyWith(
          totalCholesterolMgdl: 210,
          hdlCholesterolMgdl: 48,
          baselineSystolicMmHg: 132,
        ),
      );
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.syncNow();

      final batch = recorder.bodiesFor('/v1/readings/sync').single;
      final profile = batch['profile'] as Map<String, dynamic>;
      // The field the watch cannot measure and the score cannot do without.
      expect(profile['baseline_systolic_mmhg'], 132);
      service.dispose();
    });

    test('does not re-enrol on a second cycle', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.syncNow();
      await store.insert(_reading(at: DateTime.now().toUtc()));
      await service.syncNow();

      // Idempotent server-side, but a wasted round trip on a metered link.
      expect(recorder.countFor('/v1/patients'), 1);
      service.dispose();
    });

    test('re-enrols after the profile changes', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);
      await service.syncNow();

      await profiles.setDisplayName('M. Dela Cruz');
      await service.syncNow();

      expect(recorder.countFor('/v1/patients'), 2);
      service.dispose();
    });

    test('a cycle with nothing queued uploads no batch', () async {
      final service = serviceWith(okResponse);

      final outcome = await service.syncNow();

      expect(outcome.state, SyncState.upToDate);
      expect(recorder.countFor('/v1/readings/sync'), 0);
      service.dispose();
    });

    test('drains a backlog larger than one batch', () async {
      final now = DateTime.now().toUtc();
      for (var i = 0; i < ReadingStore.syncBatchSize + 30; i++) {
        await store.insert(_reading(at: now.subtract(Duration(minutes: i))));
      }
      final service = serviceWith(okResponse);

      await service.syncNow();

      expect(recorder.countFor('/v1/readings/sync'), 2);
      expect(await store.pendingCount(), 0);
      service.dispose();
    });
  });

  group('duplicates count as delivered', () {
    test('a re-sent batch is marked synced', () async {
      await store.insert(_reading());
      final service = serviceWith((request) {
        if (request.url.path == '/v1/readings/sync') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'patient_id': body['patient_id'],
              'stored': 0,
              'duplicates': (body['readings'] as List<dynamic>).length,
              'rejected': <String>[],
              'server_time': DateTime.now().toUtc().toIso8601String(),
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      final outcome = await service.syncNow();

      // The server already holds them, which is success from here.
      expect(outcome.duplicates, 1);
      expect(outcome.state, SyncState.upToDate);
      expect(await store.pendingCount(), 0);
      service.dispose();
    });
  });

  group('an unreachable server costs the queue nothing', () {
    test('the reading stays queued', () async {
      await store.insert(_reading());
      final service = serviceWith((_) => throw const _NoNetwork());

      final outcome = await service.syncNow();

      expect(outcome.state, SyncState.offline);
      expect(await store.pendingCount(), 1);
      service.dispose();
    });

    test('no attempt is counted against it', () async {
      // A fortnight in a dead-signal area must not quarantine a patient's whole
      // history for a fault that was never theirs.
      await store.insert(_reading());
      final service = serviceWith((_) => throw const _NoNetwork());

      for (var cycle = 0; cycle < ReadingStore.maxSyncAttempts + 3; cycle++) {
        await service.syncNow();
      }

      expect(await store.quarantinedCount(), 0);
      expect(await store.pendingCount(), 1);
      service.dispose();
    });

    test('offline is not recorded as a successful sync', () async {
      await store.insert(_reading());
      final service = serviceWith((_) => throw const _NoNetwork());

      await service.syncNow();

      expect(settings.lastSyncAt, isNull);
      service.dispose();
    });

    test('a 5xx is treated as transient, not as a refusal', () async {
      await store.insert(_reading());
      final service = serviceWith(
        (_) => http.Response('restarting', 503),
      );

      final outcome = await service.syncNow();

      expect(outcome.state, SyncState.offline);
      expect(await store.quarantinedCount(), 0);
      service.dispose();
    });
  });

  group('a refusal counts against the data', () {
    test('a 422 batch is retried but eventually set aside', () async {
      await store.insert(_reading());
      final service = serviceWith((request) {
        if (request.url.path == '/v1/readings/sync') {
          return http.Response('implausible', 422);
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      for (var cycle = 0; cycle < ReadingStore.maxSyncAttempts; cycle++) {
        final outcome = await service.syncNow();
        expect(outcome.state, SyncState.failed);
      }

      // Otherwise it would sit at the head of the oldest-first queue forever.
      expect(await store.quarantinedCount(), 1);
      expect(await store.pendingCount(), 0);
      service.dispose();
    });

    test('a poison reading stops starving the ones behind it', () async {
      final now = DateTime.now().toUtc();
      await store.insert(_reading(at: now.subtract(const Duration(hours: 2))));
      await store.insert(_reading(at: now));

      var refuse = true;
      final service = serviceWith((request) {
        if (request.url.path == '/v1/readings/sync') {
          return refuse
              ? http.Response('implausible', 422)
              : okResponse(request);
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      for (var cycle = 0; cycle < ReadingStore.maxSyncAttempts; cycle++) {
        await service.syncNow();
      }
      refuse = false;
      await service.syncNow();

      // Both were in the refused batch, so both quarantined — the point is that
      // the queue drained rather than stalling on retry forever.
      expect(await store.pendingCount(), 0);
      service.dispose();
    });

    test('a failed enrolment is reported rather than uploading regardless',
        () async {
      await store.insert(_reading());
      final service = serviceWith(
        (request) => request.url.path == '/v1/patients'
            ? http.Response('no such server', 404)
            : okResponse(request),
      );

      final outcome = await service.syncNow();

      expect(outcome.state, SyncState.failed);
      // Nothing can be stored against a patient that does not exist.
      expect(recorder.countFor('/v1/readings/sync'), 0);
      expect(await store.pendingCount(), 1);
      service.dispose();
    });
  });

  group('SOS', () {
    test('is uploaded before the readings backlog', () async {
      // An emergency is time-critical; 200 readings on a weak link take tens of
      // seconds.
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 5; i++) {
        await store.insert(_reading(at: now.subtract(Duration(minutes: i))));
      }
      await store.insertSos(triggeredAt: now, source: 'app');
      final service = serviceWith(okResponse);

      await service.syncNow();

      expect(
        recorder.paths.indexOf('/v1/sos'),
        lessThan(recorder.paths.indexOf('/v1/readings/sync')),
      );
      service.dispose();
    });

    test('is marked synced once delivered', () async {
      await store.insertSos(triggeredAt: DateTime.now().toUtc(), source: 'app');
      final service = serviceWith(okResponse);

      final outcome = await service.syncNow();

      expect(outcome.sosUploaded, 1);
      expect(await store.pendingSosCount(), 0);
      service.dispose();
    });

    test('stays queued when the server cannot be reached', () async {
      await store.insertSos(triggeredAt: DateTime.now().toUtc(), source: 'app');
      final service = serviceWith((_) => throw const _NoNetwork());

      await service.syncNow();

      // An SOS raised where there is no signal is still an SOS.
      expect(await store.pendingSosCount(), 1);
      service.dispose();
    });

    test('a refused SOS does not stop the readings backup', () async {
      await store.insert(_reading());
      await store.insertSos(triggeredAt: DateTime.now().toUtc(), source: 'app');
      final service = serviceWith(
        (request) => request.url.path == '/v1/sos'
            ? http.Response('rejected', 400)
            : okResponse(request),
      );

      await service.syncNow();

      expect(await store.pendingCount(), 0);
      expect(await store.pendingSosCount(), 1);
      service.dispose();
    });
  });

  group('backup switched off', () {
    test('uploads nothing', () async {
      await settings.setBackupEnabled(false);
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      final outcome = await service.syncNow();

      expect(outcome.state, SyncState.disabled);
      expect(recorder.paths, isEmpty);
      service.dispose();
    });

    test('still archives locally', () async {
      // Turning off backup stops data leaving the device, not the monitoring.
      await settings.setBackupEnabled(false);
      await store.insert(_reading());

      expect(await store.totalCount(), 1);
      expect(await store.pendingCount(), 1);
    });

    test('the backlog drains once it is switched back on', () async {
      await settings.setBackupEnabled(false);
      await store.insert(_reading());
      final service = serviceWith(okResponse);
      await service.syncNow();

      await settings.setBackupEnabled(true);
      await service.syncNow();

      expect(await store.pendingCount(), 0);
      service.dispose();
    });
  });

  group('status reporting', () {
    test('counts what is waiting', () async {
      await store.insert(_reading());
      final service = serviceWith(okResponse);

      await service.refreshCounts();

      expect(service.pendingCount, 1);
      service.dispose();
    });

    test('offline reads as queued, not as an error to act on', () async {
      await store.insert(_reading());
      final service = serviceWith((_) => throw const _NoNetwork());

      final outcome = await service.syncNow();

      expect(outcome.summary, contains('queued'));
      service.dispose();
    });

    test('a refusal surfaces the server message', () async {
      await store.insert(_reading());
      final service = serviceWith(
        (request) => request.url.path == '/v1/readings/sync'
            ? http.Response('implausible', 422)
            : okResponse(request),
      );

      final outcome = await service.syncNow();

      expect(outcome.summary, isNotEmpty);
      expect(outcome.state, SyncState.failed);
      service.dispose();
    });
  });
}

/// Stands in for a dead network. Thrown from the mock client so the service sees
/// the same failure shape a real socket error produces.
class _NoNetwork implements Exception {
  const _NoNetwork();
  @override
  String toString() => 'SocketException: Network is unreachable';
}
