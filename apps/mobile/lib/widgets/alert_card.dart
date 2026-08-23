/// The three informational surfaces below the vitals grid: an acute alert, a
/// service outage, and a scoring note.
///
/// Extracted from `home_screen.dart`. All three are [MecCard]s now, so they share
/// the tonal fill, hairline and radius rather than each declaring a decoration.
///
/// Severity is carried by an **icon plus words**, never by colour alone. On the
/// tonal status fill, ink stays `inkPrimary` (15.1:1) — the status hue itself is
/// 4.15:1 on that surface, fine for an icon, under AA for a sentence.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import 'mec_card.dart';

/// One acute clinical flag — an out-of-range reading and what to do about it.
class AlertCard extends StatelessWidget {
  const AlertCard({super.key, required this.flag});

  final AcuteFlag flag;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final (accent, icon, word) = switch (flag.severity) {
      Severity.critical => (
          MecRiskBand.high.color,
          Icons.dangerous_outlined,
          'CRITICAL',
        ),
      Severity.warning => (
          MecRiskBand.moderate.color,
          Icons.warning_amber_rounded,
          'WARNING',
        ),
      Severity.info => (c.series1, Icons.info_outline, 'NOTE'),
    };

    return MecCard.status(
      accent,
      // One label for the whole card, so a screen reader reads a finding as one
      // utterance instead of five fragments. The severity word leads, because it
      // is what decides whether the rest is read at all.
      semanticLabel: '$word. ${flag.vital} ${flag.displayValue}, '
          '${flag.threshold}. ${flag.message} ${flag.recommendation}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: MecSpace.s8),
              // The severity **word**, which this card did not carry before.
              // Icon plus hue was the whole signal, and the icon alone does not
              // separate warning from critical for a reader who cannot use hue
              // (docs/design.md §3.4).
              //
              // Flexible, not fixed: at a 2x text scale the word plus the vital
              // name overran the card by 27px and Flutter dropped the end of the
              // row. Verified by `test/alerts_ui_test.dart`.
              Flexible(
                child: Text(
                  word,
                  overflow: TextOverflow.ellipsis,
                  style: MecType.label.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(width: MecSpace.s8),
              Flexible(
                child: Text(
                  flag.vital,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: MecType.label.copyWith(color: c.inkSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          // Wraps rather than clipping: at a large text scale the figure and its
          // threshold cannot share a line, and the threshold is the half that a
          // Row would have truncated.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: MecSpace.s8,
            runSpacing: MecSpace.s4,
            children: [
              // The reading, at figure scale. It was previously the same size as
              // the prose around it, which made the one number the user is
              // looking for the hardest thing on the card to find.
              Text(
                flag.displayValue,
                style: MecType.statValue.copyWith(
                  color: c.inkPrimary,
                  fontSize: 26,
                ),
              ),
              // `flag.threshold` was carried on every AcuteFlag and rendered
              // nowhere, so the card stated a finding without the cut-point that
              // produced it. "88%" alone is not checkable; "88%, below 90%" is.
              Text(
                flag.threshold,
                style: MecType.axisTick.copyWith(color: c.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            flag.message,
            style: MecType.body.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s12),
          // Divided from the finding above it. The recommendation is the part
          // that asks for an action, and it previously sat in the same muted
          // grey as the sentence before it with nothing marking the change from
          // "this is what is happening" to "this is what to do".
          Container(height: 1, color: accent.withValues(alpha: 0.25)),
          const SizedBox(height: MecSpace.s12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.arrow_forward_rounded, size: 14, color: accent),
              const SizedBox(width: MecSpace.s8),
              Expanded(
                child: Text(
                  flag.recommendation,
                  style: MecType.axisTick.copyWith(
                    color: c.inkPrimary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The scoring service is unreachable.
///
/// Says plainly that vitals and acute alerts are unaffected, because they are:
/// only the ten-year score needs the network. It also offers the address, since
/// that is usually the fix.
class ServiceErrorCard extends StatelessWidget {
  const ServiceErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 18, color: c.inkSecondary),
              const SizedBox(width: MecSpace.s12),
              Expanded(
                child: Text(
                  'Risk scoring unavailable',
                  style: MecType.label.copyWith(color: c.inkPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            message,
            style: MecType.axisTick.copyWith(color: c.inkSecondary, height: 1.5),
          ),
          const SizedBox(height: MecSpace.s12),
          Text(
            'Your readings and immediate alerts are unaffected.',
            style: MecType.axisTick.copyWith(color: c.inkMuted),
          ),
          const SizedBox(height: MecSpace.s8),
          Row(
            children: [
              TextButton(onPressed: onRetry, child: const Text('Retry')),
              const SizedBox(width: MecSpace.s8),
              TextButton(
                onPressed: onOpenSettings,
                child: const Text('Change address'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A quiet footnote from the scoring model.
class ScoringNote extends StatelessWidget {
  const ScoringNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 14, color: c.inkMuted),
        const SizedBox(width: MecSpace.s8),
        Expanded(
          child: Text(
            text,
            style: MecType.axisTick.copyWith(color: c.inkMuted, height: 1.4),
          ),
        ),
      ],
    );
  }
}
