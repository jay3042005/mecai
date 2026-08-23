/// MEC-AI mobile entry point.
///
/// Dark is the default theme, not a user preference — see docs/design.md §2. The
/// Moderate amber token only clears contrast on a dark surface (1.79 on light vs
/// 9.49 on dark), so light mode needs its own review before being offered.
library;

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

import 'data/assessment_cache.dart';
import 'data/alert_notifications.dart';
import 'data/emergency_contacts.dart';
import 'data/ble_vitals_source.dart';
import 'data/monitor_controller.dart';
import 'data/profile_registry.dart';
import 'data/profile_store.dart';
import 'data/reading_store.dart';
import 'data/risk_service.dart';
import 'data/server_discovery.dart';
import 'data/settings.dart';
import 'data/sync_service.dart';
import 'design/theme.dart';
import 'screens/app_shell.dart';
import 'screens/boot_animation_screen.dart';
import 'screens/pair_watch_screen.dart';

Future<void> main() async {
  // Required before any platform channel is touched. AppSettings reads
  // SharedPreferences, which is a channel call, and this runs *before* runApp()
  // would otherwise initialize the binding.
  WidgetsFlutterBinding.ensureInitialized();
  await AlertNotifications.initialize();

  // Settings and the health profile both load before first paint, so the app
  // never renders against a placeholder and then flips.
  final settings = await AppSettings.load();

  // Who this install serves. A single-profile install is adopted as profile #1
  // with its existing identity intact, so nothing on the dashboard changes; a
  // fresh install seeds the registry from the id settings just minted. From
  // here on the registry — not the stored patient_id preference — decides who
  // readings belong to, so it must load before anything identity-shaped.
  final registry = await ProfileRegistry.load(seedPatientId: settings.patientId);
  await settings.switchPatient(registry.activeId);
  final activeId = registry.activeId;

  final profile = await ProfileStore.load(activeId, legacyOf: registry.legacyId);

  // The last server-computed score, so the risk figure is on screen at first paint
  // and stays put when the server is unreachable.
  final scores = await AssessmentCache.load();

  // Emergency contacts, loaded before first paint so the SOS button never has to
  // wait on a disk read to know who to alert.
  final contacts =
      await EmergencyContacts.load(activeId, legacyOf: registry.legacyId);

  // The readings archive opens before first paint too, so Home can render real
  // history on frame one instead of an empty chart that fills in a moment later.
  //
  // Each profile has its own archive file (see [ProfileRegistry.dbFileFor]);
  // the adopted one keeps the original name its data already lives in.
  //
  // A failure here is not fatal. Losing the archive costs history and backup;
  // losing the app costs live monitoring and the SOS button, which is worse. The
  // app runs in memory-only mode and Settings reports it.
  ReadingStore? readings;
  try {
    readings = await ReadingStore.open(
      path: p.join(await getDatabasesPath(), registry.dbFileFor(activeId)),
    );
    // Drops acknowledged rows past the retention window. Unsynced rows are never
    // pruned — they are the only copy that exists.
    await readings.prune();
  } on Object catch (error, stack) {
    debugPrint('ReadingStore unavailable, running without an archive. $error');
    debugPrintStack(stackTrace: stack);
  }

  runApp(MecApp(
    settings: settings,
    profile: profile,
    scores: scores,
    contacts: contacts,
    readings: readings,
    registry: registry,
  ));
}

class MecApp extends StatefulWidget {
  const MecApp({
    super.key,
    required this.settings,
    required this.profile,
    required this.scores,
    required this.contacts,
    required this.registry,
    this.readings,
  });

  final AppSettings settings;
  final ProfileStore profile;
  final AssessmentCache scores;
  final EmergencyContacts contacts;
  final ProfileRegistry registry;

  /// Null when SQLite could not be opened — see [main]. The app then monitors
  /// and alerts normally but keeps no history and backs nothing up.
  final ReadingStore? readings;

  @override
  State<MecApp> createState() => _MecAppState();
}

class _MecAppState extends State<MecApp> {
  late final BleVitalsSource _source;
  late final RiskService _riskService;
  late final MonitorController _controller;

  /// Open archives by profile id. Kept open rather than closed on switch:
  /// reopening SQLite costs more than holding the handle, a person who swaps
  /// between profiles gets instant history, and closing mid-write would turn a
  /// fire-and-forget archive write into a lost reading.
  final Map<String, ReadingStore> _openStores = {};

  late ProfileStore _profile;
  late EmergencyContacts _contacts;
  SyncService? _syncService;

  /// The person whose stores are actually loaded — not the registry's pointer,
  /// which [ProfileRegistry.create] moves before this state ever sees the id.
  late String _loadedProfileId;

  bool _booting = true;
  bool _showPairing = false;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
    _contacts = widget.contacts;
    _loadedProfileId = widget.registry.activeId;
    if (widget.readings != null) {
      _openStores[widget.registry.activeId] = widget.readings!;
    }
    _source = BleVitalsSource();
    _riskService = RiskService(settings: widget.settings);
    // Pairing is asked once. A completed pairing or an explicit long-hold
    // "continue without the watch" both end it; Settings offers pairing again.
    _showPairing =
        !widget.settings.watchPaired && !widget.settings.pairingDismissed;

    // Backup runs for the life of the app, not just while a screen is mounted: a
    // backlog should drain whether or not the user happens to be looking at it.
    if (widget.readings != null) {
      _syncService = SyncService(
        settings: widget.settings,
        profileStore: _profile,
        store: widget.readings!,
      )..start();
    }

    // One controller for the whole app. Four tabs need the same link, the same
    // history and the same score; four subscriptions to one BLE characteristic
    // would give four copies that drift apart.
    _controller = MonitorController(
      source: _source,
      riskService: _riskService,
      settings: widget.settings,
      profileStore: _profile,
      assessmentCache: widget.scores,
      emergencyContacts: _contacts,
      readingStore: widget.readings,
      syncService: _syncService,
    );
    _controller.start();
    _maybeAutoDiscover();
  }

  /// Asks for every permission the SOS path needs, once, up front.
  ///
  /// Historically these were only requested inside the pairing flow — so
  /// someone who skipped pairing got their first SMS/location dialog at the
  /// worst possible moment: mid-emergency, behind the SOS countdown. Asking
  /// here (after either pairing or skip resolves) means an emergency later is
  /// pure execution. Failures are logged, never fatal: a denied permission
  /// degrades one channel; a crash on startup loses all of them.
  Future<void> _requestEssentialPermissions() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await [
        Permission.sms,
        Permission.locationWhenInUse,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    } on Object catch (error) {
      debugPrint('Permission warmup failed (non-fatal). $error');
    }
  }

  /// One quiet attempt to find the scoring server on the LAN.
  ///
  /// Runs only while the address is still a factory default — someone who has
  /// typed an address, or auto-found one before, is never second-guessed. On a
  /// hit the setting updates and SyncService's settings listener uploads any
  /// backlog immediately: on a rural network where the phone and server come
  /// and go, "found the server" should mean backup starts, not waits for the
  /// next five-minute cycle.
  Future<void> _maybeAutoDiscover() async {
    if (widget.settings.apiBaseUrl != AppSettings.platformDefaultBaseUrl()) {
      return;
    }
    final found = await discoverMecaiServer(
      mdnsTimeout: const Duration(seconds: 5),
    );
    if (found == null || !mounted) return;
    await widget.settings.setApiBaseUrl(found.baseUrl);
  }

  /// Loads another person's stores and re-binds everything that is theirs.
  ///
  /// Order matters. The old sync service is detached **first**: it listens for
  /// settings changes, and re-pointing identity while the old service still
  /// lives would let its next cycle enrol the previous person's profile under
  /// the new patient id — exactly the misattribution this feature exists to
  /// prevent. With no service running, identity can move safely; the new one
  /// starts only after its stores are in hand.
  Future<void> _switchTo(String id, bool created) async {
    if (_switching || id == _loadedProfileId) return;
    _switching = true;
    try {
      // Detach before dispose: an upload cycle already in flight must not
      // notify listeners or touch these stores after ownership moves.
      _syncService?.detach();
      _syncService?.dispose();
      _syncService = null;

      await widget.settings.switchPatient(id);

      final profile = await ProfileStore.load(id);
      final contacts = await EmergencyContacts.load(id);

      var readings = _openStores[id];
      if (readings == null) {
        try {
          readings = await ReadingStore.open(
            path: p.join(
              await getDatabasesPath(),
              widget.registry.dbFileFor(id),
            ),
          );
          await readings.prune();
          _openStores[id] = readings;
        } on Object catch (error) {
          debugPrint('ReadingStore unavailable for $id. $error');
        }
      }

      SyncService? sync;
      if (readings != null) {
        sync = SyncService(
          settings: widget.settings,
          profileStore: profile,
          store: readings,
        );
      }

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _contacts = contacts;
        _syncService = sync;
        _loadedProfileId = id;
      });
      sync?.start();
      await _controller.switchProfile(
        profileStore: profile,
        emergencyContacts: contacts,
        readingStore: readings,
        syncService: sync,
      );

      // Persisted pointer. A no-op when create() already moved it.
      await widget.registry.switchTo(id);
    } finally {
      _switching = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _source.dispose();
    _riskService.dispose();
    _syncService?.dispose();
    for (final store in _openStores.values) {
      store.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MEC-AI',
      debugShowCheckedModeBanner: false,
      theme: MecTheme.light(),
      darkTheme: MecTheme.dark(),
      themeMode: ThemeMode.dark,
      home: _booting
          ? BootAnimationScreen(
              onAnimationComplete: () => setState(() => _booting = false),
            )
          : _showPairing
              ? PairWatchScreen(
                  source: _source,
                  settings: widget.settings,
                  onConnected: () {
                    unawaited(_requestEssentialPermissions());
                    setState(() => _showPairing = false);
                  },
                  onSkip: () {
                    unawaited(_requestEssentialPermissions());
                    widget.settings.setPairingDismissed(true);
                    setState(() => _showPairing = false);
                  },
                )
              : AppShell(
                  controller: _controller,
                  registry: widget.registry,
                  onSwitchProfile: _switchTo,
                ),
    );
  }
}
