/// Vitals hub — the live sensor readings, separated from the risk summary.
///
/// Home answers "what is my cardiovascular outlook"; this answers "what is the
/// watch reading right now". They were one screen, and the risk ring sat directly
/// above four sensor tiles, which invited reading the tiles as the inputs to the
/// percentage above them. They are not: the ten-year score is driven by the
/// questionnaire plus a resting systolic, and the watch's heart rate and SpO₂ feed
/// the *acute* path only.
///
/// Each card opens that vital's own screen.
library;

import 'package:flutter/material.dart';

import '../data/monitor_controller.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vital_spec.dart';
import '../models/vitals.dart';
import '../widgets/bp_estimate_card.dart';
import '../widgets/mec_bottom_nav.dart';
import '../widgets/mec_press.dart';
import '../widgets/mec_stagger.dart';
import '../widgets/vital_chart.dart';
import '../widgets/wear_banner.dart';
import 'heart_rate_screen.dart';
import 'oxygen_screen.dart';
import 'profile_screen.dart';
import 'temperature_screen.dart';

class VitalsScreen extends StatelessWidget {
  const VitalsScreen({super.key, required this.controller});

  final MonitorController controller;

  void _open(BuildContext context, VitalKind kind) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => switch (kind) {
          VitalKind.heartRate => HeartRateScreen(controller: controller),
          VitalKind.oxygen => OxygenScreen(controller: controller),
          VitalKind.bodyTemperature => TemperatureScreen(controller: controller),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final latest = controller.latest;
        final flags = controller.acuteFlags;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            MecSpace.s16,
            MecSpace.s24,
            MecSpace.s16,
            // Clears the floating nav. This was MecSpace.s16, which is 88px short
            // of the bar's reserved height — so the last two cards on this page,
            // the blood-pressure estimate and the sensor note, sat underneath it
            // and could not be scrolled into view at all.
            MecBottomNav.reservedHeight,
          ),
          children: [
            Text(
              'Live vitals',
              style: MecType.sectionTitle.copyWith(
                color: c.inkPrimary,
                fontSize: 24,
              ),
            ),
            const SizedBox(height: MecSpace.s4),
            Text(
              controller.linkState.label,
              style: MecType.label.copyWith(color: c.inkSecondary),
            ),
            const SizedBox(height: MecSpace.s16),

            WearBanner(
              wearing: controller.wearing,
              sosActive: controller.sosActive,
              onTapSos: () => controller.setSosActive(true),
              onTriggerSos: () {
                controller.setSosActive(true);
                controller.sendSosToWatch();
              },
            ),
            const SizedBox(height: MecSpace.s16),

            for (var i = 0; i < VitalSpec.all.length; i++) ...[
              MecStagger(
                index: i,
                child: _VitalCard(
                  spec: VitalSpec.all[i],
                  latest: latest,
                  history: controller.history,
                  flag: VitalSpec.all[i].flagVital.isEmpty
                      ? null
                      : flags
                          .where((f) => f.vital == VitalSpec.all[i].flagVital)
                          .firstOrNull,
                  onTap: () => _open(context, VitalSpec.all[i].kind),
                ),
              ),
              const SizedBox(height: MecSpace.s12),
            ],

            // Below the measured vitals, never among them: the tiles above are
            // sensor readings and this one is derived from them.
            MecStagger(
              index: VitalSpec.all.length,
              child: BpEstimateCard(
                estimate: controller.bpEstimate,
                onSetBaseline: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ProfileScreen(store: controller.profileStore),
                  ),
                ),
              ),
            ),

            // Named rather than hidden: a missing sensor the user was told about is
            // a known limitation; one that is silently absent looks like a bug.
            const SizedBox(height: MecSpace.s12),
            _NotMeasured(),
          ],
        );
      },
    );
  }
}

class _VitalCard extends StatelessWidget {
  const _VitalCard({
    required this.spec,
    required this.latest,
    required this.history,
    required this.flag,
    required this.onTap,
  });

  final VitalSpec spec;
  final VitalsReading? latest;
  final List<VitalsReading> history;
  final AcuteFlag? flag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final value = latest == null ? null : spec.read(latest!);

    final accent = switch (flag?.severity) {
      Severity.critical => MecRiskBand.high.color,
      Severity.warning => MecRiskBand.moderate.color,
      Severity.info => c.series1,
      null => c.series1,
    };

    return MecPress(
      child: Material(
        color: flag == null
            ? c.card
            : Color.alphaBlend(accent.withValues(alpha: MecState.hover), c.card),
        borderRadius: BorderRadius.circular(MecRadius.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(MecSpace.s16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MecRadius.card),
              border: Border.all(
                color: flag == null ? c.hairline : accent.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(spec.icon, size: 18, color: c.inkSecondary),
                    const SizedBox(width: MecSpace.s8),
                    Expanded(
                      child: Text(
                        spec.title,
                        style: MecType.body.copyWith(color: c.inkPrimary),
                      ),
                    ),
                    if (flag != null) ...[
                      // Icon + word, never hue alone.
                      Icon(
                        flag!.severity == Severity.critical
                            ? Icons.dangerous_outlined
                            : Icons.warning_amber_rounded,
                        size: 16,
                        color: accent,
                      ),
                      const SizedBox(width: MecSpace.s4),
                      Text(
                        flag!.severity == Severity.critical ? 'Critical' : 'Warning',
                        style: MecType.label.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(width: MecSpace.s4),
                    Icon(Icons.chevron_right, size: 18, color: c.inkMuted),
                  ],
                ),
                const SizedBox(height: MecSpace.s8),
                _measuredValue(c, value, accent),
                const SizedBox(height: MecSpace.s8),
                VitalChart(spec: spec, readings: history, height: 72),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _measuredValue(MecColors c, double? value, Color accent) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            spec.format(value),
            style: MecType.statValue.copyWith(color: c.inkPrimary, fontSize: 34),
          ),
          const SizedBox(width: MecSpace.s4),
          Text(
            value == null ? '' : spec.unit,
            style: MecType.label.copyWith(color: c.inkMuted),
          ),
          const Spacer(),
          if (flag != null)
            Flexible(
              child: Text(
                flag!.threshold,
                textAlign: TextAlign.right,
                style: MecType.label.copyWith(color: accent),
              ),
            )
          else if (spec.normalLabel != null)
            Flexible(
              child: Text(
                spec.normalLabel!,
                textAlign: TextAlign.right,
                style: MecType.label.copyWith(color: c.inkMuted),
              ),
            ),
        ],
      );

}

class _NotMeasured extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Container(
      padding: const EdgeInsets.all(MecSpace.s16),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(MecRadius.card),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sensors_off_outlined, size: 16, color: c.inkMuted),
              const SizedBox(width: MecSpace.s8),
              Text(
                'Not measured by this watch',
                style: MecType.label.copyWith(
                  color: c.inkSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            'This watch has no blood-pressure cuff. The blood-pressure figure '
            'above is estimated from the sensors it does have and does not '
            'trigger an alert. Use a cuff for a real reading.',
            style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
