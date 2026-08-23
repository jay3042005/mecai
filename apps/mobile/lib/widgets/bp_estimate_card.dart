/// The cuffless blood-pressure estimate card on the Vitals tab.
///
/// Every claim on this card is hedged in the copy itself, not only in a footnote:
/// the title says "Estimated", the figure carries a `~`, and the confidence line
/// is always present. That is deliberate. A number rendered in the same style as
/// the measured heart rate beside it *reads* as a measurement, and this one is
/// not — see `bp_estimator.dart`.
///
/// The shell, the ESTIMATE badge and the Low/Medium/High chip come from
/// `estimate_card.dart`, shared with the body-temperature card.
library;

import 'package:flutter/material.dart';

import '../data/bp_estimator.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'estimate_card.dart';

class BpEstimateCard extends StatelessWidget {
  const BpEstimateCard({
    super.key,
    required this.estimate,
    this.onSetBaseline,
  });

  final BpEstimate estimate;

  /// Opens the health profile. Shown only when the baseline is what is missing —
  /// an unactionable prompt is worse than none.
  final VoidCallback? onSetBaseline;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return EstimateCard(
      icon: Icons.monitor_heart_outlined,
      title: 'Estimated blood pressure',
      children: estimate.hasEstimate ? _value(c) : _missing(c),
    );
  }

  List<Widget> _value(MecColors c) => [
        // Wrap, not Row: at a 2x text scale the figure and the level chip
        // together overran the card by 301px, and a Row would have clipped the
        // chip — the half that says what the number means.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: MecSpace.s8,
          runSpacing: MecSpace.s8,
          children: [
            Text(
              // The tilde is load-bearing: it is the one mark that survives
              // someone glancing at the figure and nothing else.
              '~${estimate.display}',
              style: MecType.statValue.copyWith(
                color: c.inkPrimary,
                fontSize: 34,
              ),
            ),
            Text('mmHg', style: MecType.label.copyWith(color: c.inkMuted)),
            MecLevelChip(
              band: estimate.level!.band,
              label: estimate.level!.label,
            ),
          ],
        ),
        const SizedBox(height: MecSpace.s4),
        // The AHA stage stays, one step down in the hierarchy. The band answers
        // "should I do something"; the stage is what a clinician would want and
        // is not what the user reads first.
        Text(
          estimate.stage!.label,
          style: MecType.axisTick.copyWith(color: c.inkMuted),
        ),
        const SizedBox(height: MecSpace.s8),
        EstimateNote(icon: _confidenceIcon, text: estimate.confidence.label),
        const SizedBox(height: MecSpace.s8),
        Text(
          _derivation,
          style: MecType.axisTick.copyWith(color: c.inkMuted, height: 1.4),
        ),
        const SizedBox(height: MecSpace.s8),
        Text(
          'Calculated from your heart rate and blood oxygen against the cuff '
          'reading in your profile. It is not a measurement and must not be used '
          'to make a decision about medication — use a cuff for that.',
          style: MecType.axisTick.copyWith(color: c.inkMuted, height: 1.4),
        ),
      ];

  IconData get _confidenceIcon => switch (estimate.confidence) {
        BpConfidence.good => Icons.check_circle_outline,
        BpConfidence.fair => Icons.trending_up,
        BpConfidence.poor => Icons.help_outline,
      };

  /// Shows the arithmetic in words, so the figure is inspectable rather than
  /// oracular — the user can see it is their own resting pressure plus a shift.
  String get _derivation {
    final hr = estimate.heartRateBpm!.round();
    final resting = estimate.restingHeartRateBpm!.round();
    final delta = hr - resting;
    final direction = delta == 0
        ? 'at your resting rate'
        : delta > 0
            ? '$delta bpm above your resting $resting'
            : '${-delta} bpm below your resting $resting';
    return estimate.motionAffected
        ? 'Heart rate $hr bpm, $direction. The watch detected movement, so treat '
            'this as a direction only.'
        : 'Heart rate $hr bpm, $direction.';
  }

  List<Widget> _missing(MecColors c) => [
        EstimateNote(icon: Icons.info_outline, text: estimate.problem!),
        if (onSetBaseline != null) ...[
          const SizedBox(height: MecSpace.s4),
          TextButton(
            onPressed: onSetBaseline,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: const Text('Open health profile'),
          ),
        ],
      ];
}
