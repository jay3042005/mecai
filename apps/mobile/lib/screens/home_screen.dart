/// Home — the risk indicator and anything acute.
///
/// The clinical headline: the ten-year band, the alerts that need acting on now,
/// and nothing else. The live sensor readings moved to `vitals_screen.dart`,
/// because a risk ring sitting directly above four sensor tiles invited reading the
/// tiles as the inputs to the percentage above them. They are not — the ten-year
/// figure comes from the questionnaire plus a resting systolic, while the watch's
/// heart rate and SpO₂ drive the *acute* path only.
///
/// State lives in [MonitorController], shared with the other tabs. This file is
/// the composition.
///
/// ### Motion budget
///
/// Home is the clinical surface, so it gets Material You's **restraint**, not its
/// exuberance: tonal cards, state layers, press feedback, a staggered arrival. No
/// ring bursts, no sparkles, and nothing moving behind a number — those belong to
/// the splash and the pairing flow (docs/design.md §2 principles 3 and 5, §7). The
/// one decoration here is a static [MecAura] behind the ring.
library;

import 'package:flutter/material.dart';

import '../data/monitor_controller.dart';
import '../data/server_discovery.dart';
import '../data/server_status.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../widgets/alert_card.dart';
import '../widgets/factor_sheet.dart';
import '../widgets/home_header.dart';
import '../widgets/mec_aura.dart';
import '../widgets/mec_bottom_nav.dart';
import '../widgets/risk_ring.dart';
import '../widgets/skeleton.dart';
import '../widgets/wear_banner.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller, required this.serverStatus});

  final MonitorController controller;
  final ServerStatus serverStatus;

  void _openProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(store: controller.profileStore),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          settings: controller.settings,
          riskService: controller.riskService,
          profiles: controller.profileStore,
          syncService: controller.syncService,
          readingStore: controller.store,
        ),
      ),
    );
  }

  void _showFactors(BuildContext context) {
    final assessment = controller.assessment;
    if (assessment == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scroll-controlled so the sheet can grow past the default half-screen: a
      // complete profile produces six factors, and the default cap left four of
      // them behind a scroll inside an unnecessarily short sheet.
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      builder: (context) => FactorSheet(assessment: assessment),
    );
  }

  void _triggerSos() {
    controller.setSosActive(true);
    controller.sendSosToWatch();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return RefreshIndicator(
          onRefresh: controller.score,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              MecSpace.s16,
              MecSpace.s24,
              MecSpace.s16,
              // Clears the floating nav, so the last card is reachable.
              MecBottomNav.reservedHeight,
            ),
            children: controller.loading
                ? _skeleton(context)
                : _content(context),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) => HomeHeader(
        linkState: controller.linkState,
        wearing: controller.wearing,
        onOpenSettings: () => _openSettings(context),
        onTriggerSos: _triggerSos,
        serverStatus: serverStatus,
        onServerPress: () => _showServerSheet(context),
      );

  /// The connect sheet behind the header's server button.
  ///
  /// One tap runs the full two-stage discovery; the other hands off to
  /// Settings for a typed address. Either way [ServerStatus.probe] is what
  /// turns the header icon green, so the sheet never claims success the
  /// indicator does not corroborate.
  void _showServerSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ServerSheet(
        status: serverStatus,
        settings: controller.settings,
        onOpenSettings: () {
          Navigator.of(sheetContext).pop();
          _openSettings(context);
        },
      ),
    );
  }

  /// First load only. Geometry matches [_content] so nothing shifts on arrival.
  List<Widget> _skeleton(BuildContext context) => [
        _header(context),
        const SizedBox(height: MecSpace.s24),
        const SkeletonShimmer(
          child: Center(child: SkeletonRiskRing()),
        ),
      ];

  List<Widget> _content(BuildContext context) {
    final c = context.mec;
    final assessment = controller.assessment ?? _pending;

    return [
      _header(context),
      const SizedBox(height: MecSpace.s16),
      WearBanner(
        wearing: controller.wearing,
        sosActive: controller.sosActive,
        onTapSos: () => controller.setSosActive(true),
        onTriggerSos: _triggerSos,
      ),
      const SizedBox(height: MecSpace.s24),

      // The ring in an MD3 hero container: the largest radius in the system, a
      // tonal fill, and a single static aura for depth. The aura sits *outside*
      // RiskRing on purpose — the ring's own CustomPaint must stay its first
      // painting child, which is the footprint contract MeasureRing shares with
      // it (test/widget_test.dart, "shares the risk ring's footprint").
      Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MecSpace.s16,
          vertical: MecSpace.s24,
        ),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(MecRadius.hero),
          border: Border.all(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: MecAura.subtle(accent: assessment.band.color),
            ),
            RiskRing(
              assessment: assessment,
              onTapFactors:
                  controller.assessment == null ? null : () => _showFactors(context),
              onCompleteProfile: () => _openProfile(context),
            ),
          ],
        ),
      ),

      // Where the figure came from, and how old it is. A replayed score must be
      // legible as one — see MonitorController's docstring on why an offline
      // figure is held rather than recomputed.
      const SizedBox(height: MecSpace.s12),
      _ScoreProvenance(controller: controller),

      // Acute findings are not listed here. They live behind the Alerts
      // destination and the banner at the top of every screen — at the bottom of
      // this page they sat below the least urgent thing on it, and were invisible
      // from the other tabs entirely.
      for (final note in controller.notes) ...[
        const SizedBox(height: MecSpace.s12),
        ScoringNote(text: note),
      ],
    ];
  }

  /// Shown before the first score lands. Reuses the incomplete-profile state
  /// rather than inventing a "loading" band, so no colour is ever shown for a
  /// risk level that has not been calculated.
  static const _pending = RiskAssessment(
    band: MecRiskBand.unknown,
    valuePct: null,
    horizon: '10-year',
    factors: <RiskFactor>[],
    confidence: Confidence.incomplete,
    missingFields: <String>[],
    modelVersion: 'pending',
    disclaimer: 'Screening indicator, not a diagnosis. Consult a physician.',
  );
}

/// A one-line statement of where the displayed figure came from.
///
/// Exists because "3.6%" means different things depending on whether the server
/// computed it a second ago or four days ago. Without this the user cannot tell a
/// current score from a replayed one, and the replayed one is the normal case on a
/// device that spends most of its time out of network.
class _ScoreProvenance extends StatelessWidget {
  const _ScoreProvenance({required this.controller});

  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final origin = controller.scoreOrigin;
    if (origin == ScoreOrigin.none) return const SizedBox.shrink();

    final (icon, text) = switch (origin) {
      ScoreOrigin.server => (
          Icons.cloud_done_outlined,
          'Scored by the server just now',
        ),
      ScoreOrigin.cached => (
          Icons.cloud_off_outlined,
          'Server unreachable — showing the last score, from '
              '${_ago(controller.scoredAt)}',
        ),
      ScoreOrigin.onDevice => (
          Icons.phone_android_outlined,
          'Estimated on this phone — the server has not been reached yet',
        ),
      ScoreOrigin.none => (Icons.help_outline, ''),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 13, color: c.inkMuted),
        const SizedBox(width: MecSpace.s6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: MecType.label.copyWith(color: c.inkMuted),
          ),
        ),
      ],
    );
  }

  static String _ago(DateTime? at) {
    if (at == null) return 'an unknown time';
    final elapsed = DateTime.now().toUtc().difference(at.toUtc());
    if (elapsed.inMinutes < 1) return 'moments ago';
    if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
    if (elapsed.inHours < 24) {
      return '${elapsed.inHours} hour${elapsed.inHours == 1 ? '' : 's'} ago';
    }
    return '${elapsed.inDays} day${elapsed.inDays == 1 ? '' : 's'} ago';
  }
}

/// The server connect sheet.
class _ServerSheet extends StatefulWidget {
  const _ServerSheet({
    required this.status,
    required this.settings,
    required this.onOpenSettings,
  });

  final ServerStatus status;
  final AppSettings settings;
  final VoidCallback onOpenSettings;

  @override
  State<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends State<_ServerSheet> {
  bool _searching = false;
  String _stage = '';

  Future<void> _autoConnect() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _stage = 'Listening for the server…';
    });

    final found = await discoverMecaiServer(onStage: (stage) {
      if (!mounted) return;
      setState(() {
        _stage = stage == DiscoveryStage.mdns
            ? 'Listening for the server…'
            : 'Scanning this Wi-Fi…';
      });
    });

    if (found == null) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'No MEC-AI server found on this Wi-Fi. Make sure the laptop is '
          'running, then try again or enter the address.',
        ),
      ));
      return;
    }

    await widget.settings.setApiBaseUrl(found.baseUrl);
    await widget.status.probe();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Connected to ${found.baseUrl}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListenableBuilder(
              listenable: widget.status,
              builder: (context, _) {
                final online = widget.status.link == ServerLink.online;
                return Row(
                  children: [
                    Icon(
                      Icons.dns_rounded,
                      size: 20,
                      color:
                          online ? MecRiskBand.low.color : c.inkSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        online
                            ? 'Connected — ${widget.status.configuredAddress}'
                            : 'Server not found',
                        style: MecType.body.copyWith(color: c.inkPrimary),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _searching ? null : _autoConnect,
              icon: _searching
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.radar, size: 18),
              label: Text(
                _searching ? _stage : 'Find server automatically',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.onOpenSettings,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Enter address manually'),
            ),
          ],
        ),
      ),
    );
  }
}
