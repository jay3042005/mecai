/// The app-level acute alert strip.
///
/// ### Why this exists at the shell and not on a screen
///
/// Acute flags were only rendered on Home, below the risk ring, plus a count on
/// the Vitals tab badge. So an SpO2 of 88% recorded while the user was reading
/// Trends showed as a small number on a nav icon — the one finding in this app
/// that means *act now* was the least visible thing on screen.
///
/// Living in [AppShell] instead means the alarm is present on every tab, and it
/// occupies layout rather than floating: it pushes the page down instead of
/// covering the top of it, because an overlay that hides a vital reading to warn
/// about a vital reading is worse than the problem.
///
/// ### What it does not do
///
/// It does not replace the [AlertCard] list on Home. This says *what* is wrong in
/// one line; the cards carry the threshold and the recommendation, which is more
/// than a strip can hold and more than someone glancing at it will read.
///
/// Severity is carried by icon and words, never colour alone (docs/design.md
/// §3.4), and the strip does not animate — a throbbing red bar is a vestibular
/// hazard for someone who may be having a cardiac event (§3.6).
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import 'mec_card.dart';

class AcuteAlertBanner extends StatelessWidget {
  const AcuteAlertBanner({
    super.key,
    required this.flags,
    required this.contactsMissing,
    required this.onView,
  });

  /// Most severe first, as [evaluateAcuteFlags] returns them.
  final List<AcuteFlag> flags;

  /// No emergency contact is configured, so an SOS has nobody to text.
  ///
  /// Surfaced here rather than only on the emergency screen because that screen
  /// appears when it is already too late to fix: the countdown is running, the
  /// user is unwell, and "add a contact in Profile" is not a thing anyone does at
  /// that moment. A clinical finding outranks it — a live alarm is more urgent
  /// than an unconfigured one.
  final bool contactsMissing;

  /// Opens the alerts popup, which carries the detail and the setup action.
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    // Info-level findings are not alarms and must not take permanent space at the
    // top of every screen; they stay in the popup.
    final urgent = flags
        .where((f) =>
            f.severity == Severity.critical || f.severity == Severity.warning)
        .toList(growable: false);

    if (urgent.isEmpty) {
      return contactsMissing
          ? _SetupBanner(onView: onView)
          : const SizedBox.shrink();
    }

    final c = context.mec;
    final worst = urgent.first;
    final (accent, icon, word) = switch (worst.severity) {
      Severity.critical => (
          MecRiskBand.high.color,
          Icons.dangerous_outlined,
          'CRITICAL',
        ),
      _ => (
          MecRiskBand.moderate.color,
          Icons.warning_amber_rounded,
          'WARNING',
        ),
    };

    // "and 1 more" rather than stacking strips: two banners would push the page
    // twice as far down, and the second finding is one tap away in the popup.
    final extra = urgent.length - 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s16,
        MecSpace.s8,
        MecSpace.s16,
        0,
      ),
      child: MecCard.status(
        accent,
        onTap: onView,
        padding: const EdgeInsets.symmetric(
          horizontal: MecSpace.s12,
          vertical: MecSpace.s12,
        ),
        semanticLabel: '$word alert. ${worst.vital} ${worst.displayValue}. '
            '${worst.message} Double tap to view alerts.',
        child: Row(
          children: [
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: MecSpace.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Ink stays inkPrimary on the tonal fill: the status hue is
                    // 4.15:1 there, fine for the icon, under AA for a sentence.
                    '$word · ${worst.vital} ${worst.displayValue}',
                    style: MecType.label.copyWith(
                      color: c.inkPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: MecSpace.s4),
                  Text(
                    extra > 0
                        ? '${worst.message} And $extra more finding${extra == 1 ? '' : 's'}.'
                        : worst.message,
                    style: MecType.axisTick.copyWith(color: c.inkSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: MecSpace.s8),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: c.inkSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.onView});

  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Padding(
      padding: const EdgeInsets.fromLTRB(MecSpace.s16, MecSpace.s8, MecSpace.s16, 0),
      child: MecCard.status(
        MecRiskBand.moderate.color,
        onTap: onView,
        padding: const EdgeInsets.symmetric(horizontal: MecSpace.s12, vertical: MecSpace.s12),
        semanticLabel: 'Emergency contact not configured. Open Alerts to set one up.',
        child: Row(
          children: [
            Icon(Icons.contact_phone_outlined, size: 20, color: MecRiskBand.moderate.color),
            const SizedBox(width: MecSpace.s12),
            Expanded(
              child: Text(
                'Set up an emergency contact before using SOS',
                style: MecType.label.copyWith(color: c.inkPrimary, fontWeight: FontWeight.w700),
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: c.inkSecondary),
          ],
        ),
      ),
    );
  }
}
