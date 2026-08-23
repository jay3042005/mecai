/// The shared shell for a **derived** reading, and its Low/Medium/High chip.
///
/// Two cards on the Vitals tab show a figure the watch did not measure: the
/// cuffless blood pressure and the body temperature estimated from the enclosure
/// sensor. Both must be unmistakable as estimates, and both were about to carry
/// their own copy of the same header, the same ESTIMATE badge and the same chip.
/// One implementation instead, so a future edit that softens the hedging cannot
/// soften it on one card and not the other.
///
/// Neither card wears an alarm colour on its surface. The level chip carries the
/// status hue; the card itself stays neutral, because a red-tinted card for an
/// estimated figure would put an alarm on a number the device cannot stand behind.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';

class EstimateCard extends StatelessWidget {
  const EstimateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;

  /// Must begin with "Estimated". The badge is not the only signal — a title that
  /// reads as a measurement makes the badge a detail the user skips.
  final String title;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Container(
      padding: const EdgeInsets.all(MecSpace.s16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(MecRadius.card),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: c.inkSecondary),
              const SizedBox(width: MecSpace.s8),
              Expanded(
                child: Text(
                  title,
                  style: MecType.body.copyWith(color: c.inkPrimary),
                ),
              ),
              const EstimateBadge(),
            ],
          ),
          const SizedBox(height: MecSpace.s12),
          ...children,
        ],
      ),
    );
  }
}

/// The word, not a colour or an icon alone. The primary signal that the figure
/// below is derived rather than read off a sensor.
///
/// Public because the estimated-body-temperature vital card is a `_VitalCard`
/// rather than an [EstimateCard] — it needs the chart and the tap target — and it
/// still has to carry this badge. The alternative was a second copy of the badge in
/// `vitals_screen.dart`, which is exactly the drift this library exists to prevent.
class EstimateBadge extends StatelessWidget {
  const EstimateBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MecSpace.s8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(MecRadius.chip),
        border: Border.all(color: c.hairline),
      ),
      child: Text(
        'ESTIMATE',
        style: MecType.label.copyWith(
          color: c.inkSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Low / Medium / High, as a chip.
///
/// Word **and** icon, never the hue alone: low↔high measures ΔE 4.1 under
/// deuteranopia (docs/design.md §3.4), so a coloured chip with no text would be
/// indistinguishable between the two extremes for roughly 8% of men. The icon is
/// [riskBandIcon], the same shape channel the risk ring uses.
class MecLevelChip extends StatelessWidget {
  const MecLevelChip({super.key, required this.band, required this.label});

  final MecRiskBand band;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MecSpace.s8,
        vertical: MecSpace.s4,
      ),
      decoration: BoxDecoration(
        color: c.containerFor(band.color),
        borderRadius: BorderRadius.circular(MecRadius.chip),
        border: Border.all(color: band.color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(riskBandIcon(band), size: 13, color: band.color),
          const SizedBox(width: MecSpace.s4),
          Text(
            label.toUpperCase(),
            // inkPrimary, not the band hue: the hue measures 4.15:1 on the tonal
            // fill, fine for the icon, under AA for text.
            style: MecType.label.copyWith(
              color: c.inkPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// A muted line with a leading icon — confidence, derivation, a missing input.
class EstimateNote extends StatelessWidget {
  const EstimateNote({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: c.inkMuted),
        const SizedBox(width: MecSpace.s6),
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
