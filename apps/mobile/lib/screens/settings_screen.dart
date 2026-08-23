/// Settings — reached from the person icon on Home.
///
/// Exists primarily because there is no API address that works everywhere: the
/// Android emulator needs `10.0.2.2`, the iOS simulator needs `127.0.0.1`, and a
/// physical phone needs the host's LAN address. Baking in a constant guarantees a
/// silent connection failure for two of those three.
///
/// The text field carries no `decoration` colours of its own. It used to restate
/// the entire `InputDecorationTheme` from `design/theme.dart` — the MD3 filled
/// field, rounded on top and underlined below, is now inherited, so there is one
/// place to change it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ble_vitals_source.dart';
import '../data/reading_store.dart';
import '../data/risk_service.dart';
import '../data/sample_data.dart';
import '../data/server_discovery.dart';
import '../data/settings.dart';
import '../data/sync_service.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../widgets/mec_card.dart';
import '../widgets/mec_press.dart';
import '../widgets/mec_stagger.dart';
import 'pair_watch_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.riskService,
    this.syncService,
    this.readingStore,
    this.source,
  });

  final AppSettings settings;
  final RiskService riskService;

  /// Null when SQLite could not be opened, in which case the Backup section says
  /// so rather than showing controls that cannot do anything.
  final SyncService? syncService;
  final ReadingStore? readingStore;

  /// The BLE link, when re-pairing should be offered from here. Null on
  /// platforms where the watch cannot connect at all.
  final BleVitalsSource? source;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Outcome of a connection test, so the UI never has to infer state from nulls.
sealed class _TestResult {
  const _TestResult();
}

class _TestIdle extends _TestResult {
  const _TestIdle();
}

class _TestRunning extends _TestResult {
  const _TestRunning();
}

class _TestOk extends _TestResult {
  const _TestOk(this.health, this.url);
  final ApiHealth health;
  final String url;
}

class _TestFailed extends _TestResult {
  const _TestFailed(this.message);
  final String message;
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _controller;
  _TestResult _result = const _TestIdle();
  int _archived = 0;
  bool _finding = false;

  /// What auto-find is doing right now, shown on the button so a multi-second
  /// search never looks like a tap that did nothing.
  String _findStage = 'Listening for the server…';
  bool _seeding = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.settings.apiIpAddress);
    widget.syncService?.addListener(_onSyncChanged);
    _loadArchiveCount();
  }

  @override
  void dispose() {
    widget.syncService?.removeListener(_onSyncChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadArchiveCount() async {
    final store = widget.readingStore;
    if (store == null) return;
    final total = await store.totalCount();
    if (mounted) setState(() => _archived = total);
  }

  Future<void> _backUpNow() async {
    await widget.syncService?.syncNow();
    await _loadArchiveCount();
  }

  /// Wipes the on-device archive after an explicit confirmation.
  ///
  /// Confirmed because it is irreversible and can destroy data that never reached
  /// the server — the warning says so when there is a backlog, rather than
  /// presenting it as a harmless tidy-up.
  Future<void> _deleteLocalData() async {
    final store = widget.readingStore;
    if (store == null) return;
    final pending = widget.syncService?.pendingCount ?? 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete readings on this phone?'),
        content: Text(
          pending > 0
              ? 'This removes all $_archived stored readings, including '
                  '$pending that have not reached the server. Those are the only '
                  'copy and cannot be recovered.'
              : 'This removes all $_archived stored readings from this phone. '
                  'Readings already backed up stay on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await store.deleteAll();
    await widget.syncService?.refreshCounts();
    await _loadArchiveCount();
  }

  /// Saves first, then tests — so the field the user typed is what gets tested,
  /// and a successful test leaves the setting already persisted.
  Future<void> _saveAndTest() async {
    setState(() => _result = const _TestRunning());
    final saved = await widget.settings.setApiIpAddress(_controller.text);
    if (!saved) {
      if (mounted) {
        setState(() => _result = const _TestFailed('Enter a valid IPv4 address.'));
      }
      return;
    }

    final url = widget.settings.apiBaseUrl;
    if (!mounted) return;
    _controller.text = widget.settings.apiIpAddress;

    try {
      final health = await widget.riskService.checkHealth();
      if (!mounted) return;
      setState(() => _result = _TestOk(health, url));
    } on RiskServiceException catch (e) {
      if (!mounted) return;
      setState(() => _result = _TestFailed(e.message));
    }
  }

  Future<void> _reset() async {
    await widget.settings.resetApiBaseUrl();
    if (!mounted) return;
    setState(() {
      _controller.text = widget.settings.apiIpAddress;
      _result = const _TestIdle();
    });
  }

  /// Asks the LAN for a `_mecai._tcp` announcement instead of making the user
  /// type an address. On a hit the field and setting update together, then the
  /// normal save-and-test runs so the result card shows real confirmation —
  /// "found" that later fails to answer would be worse than not finding.
  Future<void> _autoFind() async {
    if (_finding) return;
    setState(() {
      _finding = true;
      _findStage = 'Listening for the server…';
      _result = const _TestRunning();
    });

    final found = await discoverMecaiServer(onStage: (stage) {
      if (!mounted) return;
      setState(() {
        _findStage = stage == DiscoveryStage.mdns
            ? 'Listening for the server…'
            : 'Scanning this Wi-Fi for the server…';
      });
    });

    if (found == null) {
      if (!mounted) return;
      setState(() {
        _finding = false;
        _result = const _TestFailed(
          'Searched this whole Wi-Fi and found no MEC-AI server. Check:\n'
          '• The laptop is running (launcher shows "Start Both" green)\n'
          '• This phone is on the SAME Wi-Fi as the server\n'
          '• Windows Firewall allows python.exe on Private networks',
        );
      });
      return;
    }

    await widget.settings.setApiBaseUrl(found.baseUrl);
    if (!mounted) return;
    setState(() => _controller.text = widget.settings.apiIpAddress);
    await _saveAndTest();
    if (mounted) setState(() => _finding = false);
  }

  /// Fills the active person's archive with back-dated demo readings.
  ///
  /// Everything goes through [ReadingStore.insert] like a live reading, so the
  /// backup uploads it through `POST /v1/readings/sync` unchanged and the
  /// dashboard renders it beside real data with nothing special-cased. Ids are
  /// derived from timestamps, so pressing twice does not double the history.
  Future<void> _generateSampleData() async {
    final store = widget.readingStore;
    if (store == null || _seeding) return;
    setState(() => _seeding = true);

    try {
      final patientId = widget.settings.patientId;
      final readings = generateSampleReadings(patientId: patientId);
      var inserted = 0;
      for (final reading in readings) {
        final id = sampleClientId(patientId, reading.measuredAt);
        final stored =
            await store.insert(reading, wearing: true, clientId: id);
        if (stored != null) inserted++;
      }

      // Ask for an upload soon; the normal nudge coalescing applies, exactly
      // as it would for readings arriving off a watch.
      widget.syncService?.nudge();
      widget.syncService?.refreshCounts();
      await _loadArchiveCount();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Added $inserted sample readings. Backup will upload them to the '
          'dashboard.',
        ),
      ));
    } finally {
      if (mounted) setState(() => _seeding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final running = _result is _TestRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          MecSpace.s16,
          MecSpace.s8,
          MecSpace.s16,
          MecSpace.s48,
        ),
        children: [
          const _SectionHeader(
            title: 'Scoring server',
            subtitle:
                'Where the risk model runs. Vitals still display without it.',
          ),
          const SizedBox(height: MecSpace.s16),

          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: MecType.body.copyWith(color: c.inkPrimary),
            decoration: const InputDecoration(
              labelText: 'Server IP address',
              hintText: '192.168.1.11',
              helperText: 'IPv4 only. Port $defaultApiPort is fixed.',
            ),
            onSubmitted: (_) => _saveAndTest(),
          ),

          const SizedBox(height: MecSpace.s20),
          MecPress(
            enabled: !running,
            child: FilledButton.icon(
              onPressed: running ? null : _saveAndTest,
              icon: running
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync_outlined, size: 20),
              label: Text(
                running ? 'Testing connection…' : 'Save and test connection',
              ),
            ),
          ),

          const SizedBox(height: MecSpace.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: MecPress(
              child: TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('Use default for this device'),
              ),
            ),
          ),
          const SizedBox(height: MecSpace.s4),
          Align(
            alignment: Alignment.centerLeft,
            child: MecPress(
              child: TextButton.icon(
                onPressed: _finding ? null : _autoFind,
                icon: const Icon(Icons.radar, size: 16),
                label: Text(
                  _finding
                      ? _findStage
                      : 'Find server automatically',
                ),
              ),
            ),
          ),

          const SizedBox(height: MecSpace.s8),
          _ResultCard(result: _result),

          if (!widget.settings.isPersistent) ...[
            const SizedBox(height: MecSpace.s16),
            const _StatusCard(
              status: MecRiskBand.moderate,
              icon: Icons.warning_amber_rounded,
              title: 'Address will not be saved',
              body: 'Device storage is unavailable, so this address works for '
                  'now but resets when the app restarts.',
            ),
          ],

          const SizedBox(height: MecSpace.s32),
          _SectionHeader(
            title: 'Backup',
            subtitle: widget.readingStore == null
                ? 'Unavailable on this device.'
                : 'Readings are saved on this phone first, then copied to the '
                    'server. Nothing is deleted locally when it uploads.',
          ),
          const SizedBox(height: MecSpace.s16),
          _BackupPanel(
            settings: widget.settings,
            sync: widget.syncService,
            archived: _archived,
            onBackUpNow: _backUpNow,
            onDeleteLocal: _deleteLocalData,
          ),

          const SizedBox(height: MecSpace.s32),
          _SectionHeader(
            title: 'MEC-AI watch',
            subtitle: !widget.settings.watchPaired
                ? (widget.settings.pairingDismissed
                    ? 'Skipped during setup. Pair any time — monitoring works '
                        'without it, live readings just need the watch.'
                    : 'Not paired yet.')
                : 'Paired and streaming.',
          ),
          const SizedBox(height: MecSpace.s16),
          if (widget.source != null)
            MecPress(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PairWatchScreen(
                      source: widget.source!,
                      settings: widget.settings,
                      onConnected: () => Navigator.of(context).pop(),
                      onSkip: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
                icon: const Icon(Icons.bluetooth_searching, size: 18),
                label: Text(
                  widget.settings.watchPaired ? 'Re-pair watch' : 'Pair watch',
                ),
              ),
            ),

          const SizedBox(height: MecSpace.s32),
          _SectionHeader(
            title: 'Sample data',
            subtitle: widget.readingStore == null
                ? 'Unavailable on this device.'
                : 'Adds two days of realistic back-dated readings for the '
                    'current profile. They upload through normal backup, so '
                    'the dashboard fills in too.',
          ),
          const SizedBox(height: MecSpace.s16),
          MecPress(
            enabled: widget.readingStore != null && !_seeding,
            child: OutlinedButton.icon(
              onPressed:
                  widget.readingStore == null || _seeding ? null : _generateSampleData,
              icon: _seeding
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.science_outlined, size: 18),
              label: Text(_seeding ? 'Generating…' : 'Generate sample data'),
            ),
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            // Says what it is, so sample rows can never be mistaken for a real
            // person's history once they reach the clinician dashboard.
            'Sample readings are synthetic and stay clear of every alert '
            'threshold. Delete them from the phone with "Delete local data" '
            'below; on the server they persist like any other reading.',
            style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
          ),

          const SizedBox(height: MecSpace.s32),
          const _AddressHelp(),
        ],
      ),
    );
  }
}

/// Backup state, and the two controls that act on it.
///
/// Deliberately distinguishes "cannot reach the server" from "the server refused":
/// the first needs no action from the user — the queue is intact and will retry —
/// while the second means readings are accumulating that may never be delivered.
/// Collapsing them into one "sync error" would hide that difference.
class _BackupPanel extends StatelessWidget {
  const _BackupPanel({
    required this.settings,
    required this.sync,
    required this.archived,
    required this.onBackUpNow,
    required this.onDeleteLocal,
  });

  final AppSettings settings;
  final SyncService? sync;
  final int archived;
  final Future<void> Function() onBackUpNow;
  final Future<void> Function() onDeleteLocal;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final service = sync;

    if (service == null) {
      return const _StatusCard(
        status: MecRiskBand.moderate,
        icon: Icons.sd_card_alert_outlined,
        title: 'No archive on this device',
        body: 'Local storage could not be opened, so readings are not kept '
            'between sessions and cannot be backed up. Live monitoring and '
            'alerts are unaffected.',
      );
    }

    final state = service.state;
    final pending = service.pendingCount;
    final quarantined = service.quarantinedCount;
    final busy = state.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MecCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: settings.backupEnabled,
                onChanged: (value) => settings.setBackupEnabled(value),
                title: Text(
                  'Back up to the server',
                  style: MecType.body.copyWith(color: c.inkPrimary),
                ),
                subtitle: Text(
                  'Off keeps every reading on this phone only.',
                  style: MecType.label.copyWith(color: c.inkSecondary),
                ),
              ),
              const Divider(height: MecSpace.s24),
              _BackupStat(label: 'Stored on this phone', value: '$archived'),
              _BackupStat(
                label: 'Waiting to upload',
                value: '$pending',
                emphasis: pending > 0,
              ),
              _BackupStat(
                label: 'Last backup',
                value: _relative(settings.lastSyncAt),
              ),
            ],
          ),
        ),
        const SizedBox(height: MecSpace.s12),
        Row(
          children: [
            Expanded(
              child: MecPress(
                enabled: !busy && settings.backupEnabled,
                child: FilledButton.icon(
                  onPressed: busy || !settings.backupEnabled ? null : onBackUpNow,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.backup_outlined, size: 20),
                  label: Text(busy ? 'Backing up…' : 'Back up now'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: MecSpace.s8),
        Align(
          alignment: Alignment.centerLeft,
          child: MecPress(
            enabled: archived > 0,
            child: TextButton.icon(
              onPressed: archived > 0 ? onDeleteLocal : null,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete readings on this phone'),
            ),
          ),
        ),
        if (state != SyncState.idle) ...[
          const SizedBox(height: MecSpace.s8),
          _StatusCard(
            status: switch (state) {
              SyncState.upToDate => MecRiskBand.low,
              SyncState.failed => MecRiskBand.high,
              // Offline is expected on this device, not a fault to alarm about.
              SyncState.offline || SyncState.disabled => MecRiskBand.moderate,
              _ => MecRiskBand.unknown,
            },
            icon: switch (state) {
              SyncState.upToDate => Icons.cloud_done_outlined,
              SyncState.failed => Icons.error_outline,
              SyncState.offline => Icons.cloud_off_outlined,
              SyncState.disabled => Icons.pause_circle_outline,
              _ => Icons.cloud_sync_outlined,
            },
            title: switch (state) {
              SyncState.upToDate => 'Backed up',
              SyncState.failed => 'The server refused the upload',
              SyncState.offline => 'Server unreachable',
              SyncState.disabled => 'Backup is off',
              _ => 'Backing up',
            },
            body: service.lastOutcome.summary,
          ),
        ],
        if (quarantined > 0) ...[
          const SizedBox(height: MecSpace.s8),
          _StatusCard(
            status: MecRiskBand.high,
            icon: Icons.report_problem_outlined,
            title: '$quarantined reading${quarantined == 1 ? '' : 's'} could not '
                'be backed up',
            body: 'The server rejected these repeatedly, so they are no longer '
                'retried. They are still on this phone. Check that the server '
                'address points at a matching MEC-AI version.',
          ),
        ],
      ],
    );
  }

  /// Relative time, because an absolute timestamp answers the wrong question —
  /// "is my data safe right now" is about elapsed time, not clock time.
  static String _relative(DateTime? at) {
    if (at == null) return 'Never';
    final elapsed = DateTime.now().toUtc().difference(at.toUtc());
    if (elapsed.inMinutes < 1) return 'Just now';
    if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
    if (elapsed.inHours < 24) {
      return '${elapsed.inHours} hour${elapsed.inHours == 1 ? '' : 's'} ago';
    }
    return '${elapsed.inDays} day${elapsed.inDays == 1 ? '' : 's'} ago';
  }
}

class _BackupStat extends StatelessWidget {
  const _BackupStat({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MecSpace.s4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: MecType.label.copyWith(color: c.inkSecondary)),
          Text(
            value,
            style: MecType.statValue.copyWith(
              // The band enum owns its own hue, so this tracks the palette
              // instead of restating a colour that could drift from it.
              color: emphasis ? MecRiskBand.moderate.color : c.inkPrimary,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: MecType.sectionTitle.copyWith(color: c.inkPrimary)),
        const SizedBox(height: MecSpace.s4),
        Text(
          subtitle,
          style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
        ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final _TestResult result;

  @override
  Widget build(BuildContext context) {
    return switch (result) {
      _TestIdle() || _TestRunning() => const SizedBox.shrink(),
      _TestOk(:final health, :final url) => _StatusCard(
          // Amber when the server scores but cannot store: readings will be
          // scored and then dropped, which "Connected" alone would not convey.
          status: health.storage ? MecRiskBand.low : MecRiskBand.moderate,
          // The word carries it; the colour is on the icon.
          icon: health.storage
              ? Icons.check_circle_outline
              : Icons.warning_amber_rounded,
          title: health.storage ? 'Connected' : 'Connected, but not storing',
          body: 'API $url\n'
              'Version ${health.version}\n'
              'Risk model ${health.riskModel}\n'
              '${health.readings} readings from ${health.patients} '
              'patient${health.patients == 1 ? '' : 's'} on file',
          footer: [
            if (!health.storage)
              'This server cannot write its readings archive, so backups will '
                  'not be kept. Check its database path.',
            if (health.mockEndpoints)
              'Mock endpoints are enabled — this server serves synthetic '
                  'readings. Disable them before any real use.',
          ].join('\n\n').ifEmptyNull,
        ),
      _TestFailed(:final message) => _StatusCard(
          status: MecRiskBand.high,
          icon: Icons.error_outline,
          title: 'Not connected',
          body: message,
        ),
    };
  }
}

/// An outcome card, tinted by a status band.
///
/// Ink stays `inkPrimary` on the tonal fill; the band colour is carried by the
/// icon, which needs 3:1 rather than the 4.5:1 a sentence would.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.icon,
    required this.title,
    required this.body,
    this.footer,
  });

  final MecRiskBand status;
  final IconData icon;
  final String title;
  final String body;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return MecCard.status(
      status.color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: status.color),
              const SizedBox(width: MecSpace.s12),
              Text(title, style: MecType.label.copyWith(color: c.inkPrimary)),
            ],
          ),
          const SizedBox(height: MecSpace.s12),
          Text(
            body,
            style: MecType.axisTick.copyWith(color: c.inkSecondary, height: 1.5),
          ),
          if (footer != null) ...[
            const SizedBox(height: MecSpace.s12),
            Text(
              footer!,
              style: MecType.axisTick.copyWith(
                color: c.inkSecondary,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The three cases, spelled out. This is the whole reason the setting exists.
class _AddressHelp extends StatelessWidget {
  const _AddressHelp();

  static const _rows = <(String, String)>[
    ('Android emulator', '10.0.2.2:$defaultApiPort'),
    ('iOS simulator', '127.0.0.1:$defaultApiPort'),
    ('Phone on Wi-Fi', "your computer's IP, e.g. 192.168.1.11:$defaultApiPort"),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Which address to use',
            style: MecType.label.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s12),
          for (var i = 0; i < _rows.length; i++)
            MecStagger(
              index: i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: MecSpace.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _rows[i].$1,
                      style: MecType.axisTick.copyWith(color: c.inkMuted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _rows[i].$2,
                      style: MecType.axisTick.copyWith(color: c.inkSecondary),
                    ),
                  ],
                ),
              ),
            ),
          Divider(color: c.gridline, height: MecSpace.s24),
          Text(
            'A phone cannot reach 127.0.0.1 or 10.0.2.2 — those point at the '
            'phone itself. On a physical device, the API must also be started '
            'bound to your network rather than loopback:',
            style: MecType.axisTick.copyWith(color: c.inkSecondary, height: 1.5),
          ),
          const SizedBox(height: MecSpace.s8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(MecSpace.s12),
            decoration: BoxDecoration(
              color: c.page,
              borderRadius: BorderRadius.circular(MecRadius.sm),
            ),
            child: Text(
              'uvicorn mecai_api.main:app --host 0.0.0.0 --port $defaultApiPort',
              style: MecType.axisTick.copyWith(color: c.inkSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

extension _EmptyToNull on String {
  /// `null` for an empty string, so an optional footer collapses rather than
  /// rendering an empty block.
  String? get ifEmptyNull => isEmpty ? null : this;
}
