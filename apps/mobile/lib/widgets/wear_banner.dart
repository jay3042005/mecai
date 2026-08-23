/// Whether the watch is on a wrist — and, when it matters, that SOS is live.
///
/// Two states in one strip, because they answer the same question: is this data
/// real right now.
///
/// The heartbeat on the "worn" dot and the throb on the SOS banner are the one
/// kind of motion docs/design.md §2 principle 3 permits — they mean *liveness*,
/// not decoration. Both stop dead under reduced motion, which the version this
/// replaces did not do: a throbbing red banner is a vestibular hazard for someone
/// who may be having a cardiac event (§3.6).
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_card.dart';

class WearBanner extends StatefulWidget {
  const WearBanner({
    super.key,
    required this.wearing,
    required this.sosActive,
    required this.onTapSos,
    required this.onTriggerSos,
  });

  final bool wearing;
  final bool sosActive;
  final VoidCallback onTapSos;
  final VoidCallback onTriggerSos;

  @override
  State<WearBanner> createState() => _WearBannerState();
}

class _WearBannerState extends State<WearBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: MecMotion.ambient,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(WearBanner old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// The pulse runs only while there is liveness to convey, and never under
  /// reduced motion.
  void _sync() {
    final wanted =
        (widget.wearing || widget.sosActive) && !context.reduceMotion;

    if (wanted && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!wanted && _pulse.isAnimating) {
      _pulse.stop();
      // Fully lit rather than mid-fade, so a stopped pulse never reads as dim.
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.sosActive ? _sos(context) : _wear(context);
  }

  Widget _sos(BuildContext context) {
    final c = context.mec;

    return MecCard.status(
      MecAlarm.color,
      onTap: widget.onTapSos,
      padding: const EdgeInsets.all(MecSpace.s12),
      child: Row(
        children: [
          FadeTransition(
            opacity: _pulse,
            child: const Icon(Icons.warning_rounded, color: MecAlarm.color),
          ),
          const SizedBox(width: MecSpace.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The words carry the state; the red is on the icon, which needs
                // 3:1 rather than the 4.5:1 a label would.
                Text(
                  'EMERGENCY SOS ACTIVE',
                  style: MecType.label.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Tap to view emergency call and dispatch status',
                  style: MecType.axisTick.copyWith(color: c.inkSecondary),
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_ios_rounded, size: 14, color: c.inkSecondary),
        ],
      ),
    );
  }

  Widget _wear(BuildContext context) {
    final c = context.mec;
    final worn = widget.wearing;

    return MecCard(
      radius: MecRadius.pill,
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s16,
        MecSpace.s8,
        MecSpace.s8,
        MecSpace.s8,
      ),
      child: Row(
        children: [
          if (worn)
            FadeTransition(
              opacity: _pulse,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: MecRiskBand.low.color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: MecRiskBand.low.color.withValues(alpha: 0.6),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            )
          else
            Icon(Icons.radio_button_unchecked, size: 12, color: c.inkMuted),
          const SizedBox(width: MecSpace.s12),
          Expanded(
            child: Text(
              worn
                  ? 'ON WRIST — Live monitoring'
                  : 'NOT WORN — Place MEC-AI on your wrist',
              style: MecType.label.copyWith(
                color: worn ? c.inkPrimary : c.inkSecondary,
                fontWeight: worn ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          IconButton(
            onPressed: widget.onTriggerSos,
            icon: const Icon(Icons.sos_rounded, color: MecAlarm.color, size: 22),
            tooltip: 'Trigger Emergency SOS',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
