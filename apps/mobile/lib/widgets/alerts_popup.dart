/// The acute alerts popup, anchored to the top of the screen.
///
/// ### Why a popup and not a section on Home
///
/// The alert list used to sit at the bottom of Home, below the risk ring and the
/// provenance line. That put the one finding in this app that means *act now*
/// below the fold of the least urgent thing on the page, and made it invisible
/// from the other three tabs entirely.
///
/// Now the findings live here, reachable from the Alerts destination on the nav
/// and from the banner at the top of every screen. Home keeps the chronic score,
/// which is what it is for.
///
/// ### Why it sits at the top
///
/// It is opened either by the banner it replaces — which is at the top — or by
/// the nav at the bottom. Anchoring to the top keeps the sheet clear of a thumb
/// still resting on the nav bar, so the tap that opens it cannot immediately
/// dismiss it by hitting a card underneath.
///
/// Motion is a fade only. A panel that slides down over a screen someone opened
/// because they feel unwell is a vestibular trigger (docs/design.md §3.6), so
/// there is no travel to suppress under reduced motion.
///
/// ### Ordering, and why the header counts what it counts
///
/// Findings arrive most-severe-first from `evaluateAcuteFlags`, and the list
/// keeps that order. The header counts only critical and warning findings —
/// matching the nav badge, which counts the same thing. A header that said
/// "Alerts (3)" while the badge said 2 would leave the user hunting for a third
/// alarm that is really an informational note.
library;

import 'package:flutter/material.dart';

import '../data/emergency_contacts.dart';
import '../data/location_service.dart';
import '../data/sos_dispatcher.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import '../screens/emergency_contacts_screen.dart';
import 'alert_card.dart';
import 'mec_card.dart';

/// Shows [flags] in a top-anchored popup. Returns when it is dismissed.
Future<void> showAcuteAlertsPopup(
  BuildContext context, {
  required List<AcuteFlag> flags,
  required EmergencyContacts contacts,
  required LocationService locationService,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss alerts',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: context.stilled(MecMotion.fast),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: MecEasing.standard),
      child: child,
    ),
    pageBuilder: (context, _, _) => _AlertsPopup(
      flags: flags,
      contacts: contacts,
      locationService: locationService,
    ),
  );
}

class _AlertsPopup extends StatelessWidget {
  const _AlertsPopup({
    required this.flags,
    required this.contacts,
    required this.locationService,
  });

  final List<AcuteFlag> flags;
  final EmergencyContacts contacts;
  final LocationService locationService;

  /// Findings that need acting on, matching the nav badge. See the library note.
  int get _urgentCount => flags
      .where((f) =>
          f.severity == Severity.critical || f.severity == Severity.warning)
      .length;

  int get _noteCount => flags.length - _urgentCount;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final media = MediaQuery.of(context);
    final worst = flags.firstOrNull?.severity;

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(MecSpace.s16),
          // The shadow sits on a wrapper **outside** the Material, not on the
          // container inside it: that Material clips to its border radius, so a
          // shadow declared within it is clipped away by the very shape it is
          // meant to lift off the page.
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MecRadius.card),
              boxShadow: MecElevation.raised,
            ),
            child: Material(
              color: c.card,
              borderRadius: BorderRadius.circular(MecRadius.card),
              clipBehavior: Clip.antiAlias,
              child: Container(
                // Bounded so a long list scrolls inside the popup rather than
                // running off the screen it is anchored to.
                constraints: BoxConstraints(
                  maxHeight: media.size.height * 0.72,
                  maxWidth: 560,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(MecRadius.card),
                  border: Border.all(color: c.hairline),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                      urgent: _urgentCount,
                      notes: _noteCount,
                      worst: worst,
                      onClose: () => Navigator.of(context).pop(),
                    ),
                    Flexible(
                      child: flags.isEmpty && !contacts.isEmpty
                          ? const _AllClear()
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(
                                MecSpace.s16,
                                MecSpace.s12,
                                MecSpace.s16,
                                MecSpace.s16,
                              ),
                              children: [
                                if (contacts.isEmpty) ...[
                                  _ContactSetupCard(
                                    contacts: contacts,
                                    locationService: locationService,
                                  ),
                                  if (flags.isNotEmpty)
                                    const SizedBox(height: MecSpace.s12),
                                ],
                                for (var i = 0; i < flags.length; i++) ...[
                                  // A rule above the first note, so the shift
                                  // from "act on this" to "for your information"
                                  // is visible rather than only implied by the
                                  // colour of a card in a stack of cards.
                                  if (_startsNotes(i)) ...[
                                    _GroupLabel(count: _noteCount),
                                    const SizedBox(height: MecSpace.s8),
                                  ],
                                  AlertCard(flag: flags[i]),
                                  if (i != flags.length - 1)
                                    const SizedBox(height: MecSpace.s12),
                                ],
                              ],
                            ),
                    ),
                    _Footer(worst: worst),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// True at the first info-level finding, when urgent ones precede it.
  bool _startsNotes(int i) =>
      flags[i].severity == Severity.info &&
      _urgentCount > 0 &&
      (i == 0 || flags[i - 1].severity != Severity.info);
}

/// The popup title, coloured and worded by the worst finding present.
class _Header extends StatelessWidget {
  const _Header({
    required this.urgent,
    required this.notes,
    required this.worst,
    required this.onClose,
  });

  final int urgent;
  final int notes;
  final Severity? worst;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    final (accent, icon, title) = switch (worst) {
      Severity.critical => (
          MecRiskBand.high.color,
          Icons.dangerous_outlined,
          urgent == 1 ? 'Critical finding' : '$urgent findings need attention',
        ),
      Severity.warning => (
          MecRiskBand.moderate.color,
          Icons.warning_amber_rounded,
          urgent == 1 ? 'Reading out of range' : '$urgent readings out of range',
        ),
      Severity.info => (c.series1, Icons.info_outline, 'For your information'),
      null => (MecRiskBand.low.color, Icons.check_circle_outline, 'No active alerts'),
    };

    return Container(
      // A tonal band rather than a plain row: it separates the title from the
      // scrolling list underneath, which previously ran straight into it with
      // nothing between them once the list was scrolled.
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s16,
        MecSpace.s12,
        MecSpace.s8,
        MecSpace.s12,
      ),
      decoration: BoxDecoration(
        color: c.containerFor(accent),
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: accent),
          const SizedBox(width: MecSpace.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  // inkPrimary on the tonal fill: the status hue measures 4.15:1
                  // there, fine for the icon, under AA for a heading.
                  style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
                ),
                if (notes > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    'and $notes note${notes == 1 ? '' : 's'}',
                    style: MecType.axisTick.copyWith(color: c.inkSecondary),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
            color: c.inkSecondary,
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s16,
        MecSpace.s16,
        MecSpace.s16,
        MecSpace.s24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Every reading is within its normal range.',
            style: MecType.body.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s12),
          // Naming the cut-points turns "nothing is wrong" into a checkable
          // statement. The bare reassurance gave no way to tell a healthy user
          // from a stalled sensor. Read from MecAlert rather than typed as prose,
          // so the reassurance cannot claim a threshold the engine does not use.
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

/// Separates informational notes from the alarms above them.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Padding(
      padding: const EdgeInsets.only(top: MecSpace.s12, bottom: MecSpace.s4),
      child: Row(
        children: [
          Text(
            count == 1 ? 'FOR INFORMATION' : 'FOR INFORMATION ($count)',
            style: MecType.label.copyWith(
              color: c.inkMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: MecSpace.s8),
          Expanded(child: Container(height: 1, color: c.hairline)),
        ],
      ),
    );
  }
}

/// The disclaimer, pinned below the scroll.
///
/// Pinned rather than appended to the list: at the bottom of a scrolling column
/// of cards it is the one thing a user reading an alarm never reaches, and "this
/// is not a diagnosis" is not a footnote that may go unread on a screen telling
/// someone to seek emergency care.
class _Footer extends StatelessWidget {
  const _Footer({required this.worst});

  final Severity? worst;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s16,
        MecSpace.s12,
        MecSpace.s16,
        MecSpace.s12,
      ),
      decoration: BoxDecoration(
        color: c.elevated,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: c.inkMuted),
          const SizedBox(width: MecSpace.s8),
          Expanded(
            child: Text(
              worst == Severity.critical
                  ? 'Screening readings from a wearable sensor, not a diagnosis. '
                      'If you feel unwell, seek care now — do not wait for '
                      'another reading.'
                  : 'Screening readings from a wearable sensor, not a diagnosis. '
                      'A clinician interprets these.',
              style: MecType.axisTick.copyWith(color: c.inkMuted, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "no emergency contact" prompt.
///
/// The action is a full-width button rather than the `TextButton` this replaces,
/// which was squeezed to the right of two lines of text — at that size it was the
/// smallest target in the popup, and it is the only actionable thing on the card.
class _ContactSetupCard extends StatelessWidget {
  const _ContactSetupCard({required this.contacts, required this.locationService});

  final EmergencyContacts contacts;
  final LocationService locationService;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final accent = MecRiskBand.moderate.color;

    return MecCard.status(
      accent,
      semanticLabel: 'Emergency contact not set up. SOS cannot send an SMS '
          'until one is added.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.contact_phone_outlined, size: 18, color: accent),
              const SizedBox(width: MecSpace.s8),
              Text(
                'SETUP NEEDED',
                style: MecType.label.copyWith(
                  color: c.inkPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            'SOS cannot send an SMS until an emergency contact is set up.',
            style: MecType.body.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EmergencyContactsScreen(
                    contacts: contacts,
                    locationService: locationService,
                    dispatcher: const SosDispatcher(),
                  ),
                ),
              ),
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: const Text('Add emergency contact'),
            ),
          ),
        ],
      ),
    );
  }
}
