/// Alerts — every acute finding, as a real destination.
///
/// Was a top-anchored popup; the client asked for a page like the other tabs,
/// and they were right about the ergonomics: a popup dismisses on an accidental
/// tap outside it, cannot be scrolled with purpose, and hides its own existence
/// from the tab bar's sense of place. A page stays put while someone reads.
///
/// Content is ordered the way the popup ordered it — alarms first, then
/// informational notes behind a visible divider — because that split is the
/// whole point of this screen: "act now" versus "for your awareness". The nav
/// badge counts only the first group, so this header and that badge can never
/// disagree about how many things need acting on.
library;

import 'package:flutter/material.dart';

import '../data/emergency_contacts.dart';
import '../data/location_service.dart';
import '../data/monitor_controller.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../widgets/alert_card.dart';
import '../widgets/mec_bottom_nav.dart';
import '../widgets/mec_card.dart';
import 'emergency_contacts_screen.dart';

class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key, required this.controller});

  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        controller.emergencyContacts,
      ]),
      builder: (context, _) {
        final flags = controller.acuteFlags;
        final urgent = flags
            .where((f) =>
                f.severity == Severity.critical ||
                f.severity == Severity.warning)
            .length;
        final notes = flags.length - urgent;
        final worst = flags.firstOrNull?.severity;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            MecSpace.s16,
            MecSpace.s24,
            MecSpace.s16,
            MecBottomNav.reservedHeight,
          ),
          children: [
            _Title(urgent: urgent, notes: notes, worst: worst),
            const SizedBox(height: MecSpace.s16),
            if (controller.emergencyContacts.isEmpty) ...[
              _ContactSetupCard(
                contacts: controller.emergencyContacts,
                locationService: controller.locationService,
              ),
              if (flags.isNotEmpty) const SizedBox(height: MecSpace.s16),
            ],
            if (flags.isEmpty)
              const _AllClear()
            else ...[
              for (var i = 0; i < flags.length; i++) ...[
                if (_startsNotes(flags, i)) ...[
                  _GroupLabel(count: notes),
                  const SizedBox(height: MecSpace.s8),
                ],
                AlertCard(flag: flags[i]),
                if (i != flags.length - 1)
                  const SizedBox(height: MecSpace.s12),
              ],
            ],
            const SizedBox(height: MecSpace.s24),
            Text(
              // Persistent product requirement (README → Privacy), not a
              // footnote: acute findings are screening signals with advice,
              // never a diagnosis of anything.
              'Screening indicator, not a diagnosis. Consult a physician.',
              textAlign: TextAlign.center,
              style: MecType.label.copyWith(color: c.inkMuted),
            ),
          ],
        );
      },
    );
  }

  /// True at the first info-level finding, when urgent ones precede it.
  static bool _startsNotes(List<AcuteFlag> flags, int i) =>
      flags[i].severity == Severity.info &&
      flags.any((f) => f.severity != Severity.info) &&
      (i == 0 || flags[i - 1].severity != Severity.info);
}

class _Title extends StatelessWidget {
  const _Title({
    required this.urgent,
    required this.notes,
    required this.worst,
  });

  final int urgent;
  final int notes;
  final Severity? worst;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final colour = switch (worst) {
      Severity.critical => MecRiskBand.high.color,
      Severity.warning => MecRiskBand.moderate.color,
      Severity.info => c.series1,
      null => MecRiskBand.low.color,
    };
    final line = switch ((urgent, notes)) {
      (0, 0) => 'Every reading is within its normal range.',
      (0, _) => '$notes informational note${notes == 1 ? '' : 's'}.',
      (_, 0) => '$urgent need${urgent == 1 ? 's' : ''} your attention.',
      (_, _) => '$urgent need attention · $notes note${notes == 1 ? '' : 's'}.',
    };

    return Row(
      children: [
        Icon(
          worst == null ? Icons.verified_user_outlined : Icons.notifications_active_rounded,
          size: 22,
          color: colour,
        ),
        const SizedBox(width: MecSpace.s8),
        Expanded(
          child: Text(
            'Alerts',
            style: MecType.sectionTitle.copyWith(
              color: c.inkPrimary,
              fontSize: 22,
            ),
          ),
        ),
        Text(
          line,
          style: MecType.label.copyWith(color: c.inkSecondary),
        ),
      ],
    );
  }
}

/// Nothing is wrong. Says what is being watched, so an empty list reads as a
/// working monitor rather than a feature that has not started.
class _AllClear extends StatelessWidget {
  const _AllClear();

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Every reading is within its normal range.',
            style: MecType.body.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s12),
          // Naming the cut-points turns "nothing is wrong" into a checkable
          // statement rather than a bare reassurance. Read from MecAlert so the
          // copy cannot claim a threshold the engine does not use.
          for (final line in <String>[
            'Blood oxygen at or above ${MecAlert.spo2Warning.round()}%',
            'Heart rate ${MecAlert.heartRateLowWarning.round()}'
                '–${MecAlert.heartRateHighWarning.round()} bpm',
            'Body temperature below '
                '${MecAlert.temperatureFeverWarning.toStringAsFixed(1)} °C',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: MecSpace.s4),
              child: Row(
                children: [
                  Icon(Icons.check, size: 14, color: MecRiskBand.low.color),
                  const SizedBox(width: MecSpace.s8),
                  Text(
                    line,
                    style: MecType.axisTick.copyWith(color: c.inkSecondary),
                  ),
                ],
              ),
            ),
          const SizedBox(height: MecSpace.s8),
          Text(
            'Checked continuously while the watch is worn.',
            style: MecType.axisTick.copyWith(color: c.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// The SOS path is only as good as its contact list; an empty one is worth a
/// permanent prompt until fixed.
class _ContactSetupCard extends StatelessWidget {
  const _ContactSetupCard({
    required this.contacts,
    required this.locationService,
  });

  final EmergencyContacts contacts;
  final LocationService locationService;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: MecRiskBand.moderate.color),
              const SizedBox(width: MecSpace.s8),
              Expanded(
                child: Text(
                  'No emergency contacts set',
                  style: MecType.body.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            'Pressing SOS will record the emergency and your location, but no '
            'message will be sent to anyone.',
            style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
          ),
          const SizedBox(height: MecSpace.s12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => EmergencyContactsScreen(
                  contacts: contacts,
                  locationService: locationService,
                ),
              ),
            ),
            icon: const Icon(Icons.contact_phone_outlined, size: 18),
            label: const Text('Add an emergency contact'),
          ),
        ],
      ),
    );
  }
}

/// Separates informational notes from the alarms above them.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Padding(
      padding: const EdgeInsets.only(top: MecSpace.s4),
      child: Row(
        children: [
          Text(
            'FOR YOUR INFORMATION',
            style: MecType.label.copyWith(
              color: c.inkMuted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: MecSpace.s8),
          Text(
            '$count',
            style: MecType.label.copyWith(color: c.inkMuted),
          ),
        ],
      ),
    );
  }
}
