/// What drove the risk score — the bottom sheet behind the factor chip.
///
/// A score the user cannot interrogate is not trustworthy, so this is always
/// reachable from the ring. Extracted from `home_screen.dart`.
///
/// Each row names the input, its value, its relative weight, and — the part users
/// are entitled to — whether the watch measured it or they told us. Bars are
/// relative weights within the model, never individual risk percentages, which is
/// stated rather than implied.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import 'mec_stagger.dart';

class FactorSheet extends StatelessWidget {
  const FactorSheet({super.key, required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s24,
        0,
        MecSpace.s24,
        MecSpace.s32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The heading and the caveat stay pinned while the rows scroll. A
          // complete profile yields six factors, which overflowed the sheet as a
          // fixed column — and scrolling the caveat out of view would leave the
          // bars readable as individual risk percentages, which is precisely what
          // they are not.
          Text(
            'What drove this score',
            style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s4),
          Text(
            'Relative weight within the ${assessment.modelVersion} model. '
            'These are not individual risk percentages.',
            style: MecType.axisTick.copyWith(color: c.inkMuted, height: 1.4),
          ),
          const SizedBox(height: MecSpace.s24),
          Flexible(
            child: ListView.builder(
              // Sizes to its content when the rows fit, and scrolls when they do
              // not — so a two-factor sheet stays short instead of padding itself
              // out to the full height.
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: assessment.factors.length,
              itemBuilder: (context, i) => MecStagger(
                index: i,
                child: _FactorRow(factor: assessment.factors[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FactorRow extends StatelessWidget {
  const _FactorRow({required this.factor});

  final RiskFactor factor;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Padding(
      padding: const EdgeInsets.only(bottom: MecSpace.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  factor.name,
                  style: MecType.body.copyWith(color: c.inkPrimary),
                ),
              ),
              Text(
                factor.displayValue,
                style: MecType.axisTick.copyWith(color: c.inkSecondary),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          ClipRRect(
            borderRadius: BorderRadius.circular(MecRadius.pill),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: factor.contribution),
              duration: context.stilled(MecMotion.value),
              curve: MecEasing.decelerate,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                backgroundColor: c.gridline,
                valueColor: AlwaysStoppedAnimation<Color>(c.series1),
              ),
            ),
          ),
          const SizedBox(height: MecSpace.s4),
          // Wrap, not Row: "From your profile" and "· you can change this"
          // together overrun a narrow phone's line width, and both are worth
          // keeping — the second is the actionable half. Ellipsising it would cut
          // exactly the part that tells the user they can do something.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: MecSpace.s4,
            runSpacing: MecSpace.s2,
            children: [
              Icon(
                factor.source == FactorSource.device
                    ? Icons.sensors
                    : Icons.assignment_outlined,
                size: 12,
                color: c.inkMuted,
              ),
              Text(
                factor.source.label,
                style: MecType.axisTick.copyWith(color: c.inkMuted),
              ),
              if (factor.modifiable)
                Text(
                  '· you can change this',
                  style: MecType.axisTick.copyWith(color: c.inkMuted),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
