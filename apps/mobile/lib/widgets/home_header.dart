/// The home screen's top bar: identity, link state, and the SOS escape hatch.
///
/// Extracted from `home_screen.dart` so the screen composes rather than draws.
///
/// The link chip states the connection in words as well as a dot, because a
/// coloured dot alone is not a readable status — the same rule the risk indicator
/// follows, applied to chrome.
library;

import 'package:flutter/material.dart';

import '../data/vitals_source.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_press.dart';

class HomeHeader extends StatelessWidget {
  const HomeHeader({
    super.key,
    required this.linkState,
    required this.wearing,
    required this.onOpenSettings,
    required this.onTriggerSos,
  });

  final LinkState linkState;
  final bool wearing;
  final VoidCallback onOpenSettings;
  final VoidCallback onTriggerSos;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final connected = linkState.isLinked;

    var status = linkState.label;
    if (connected) status += wearing ? ' · Worn' : ' · Off';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MEC-AI',
                style: MecType.sectionTitle.copyWith(
                  color: c.inkPrimary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: MecSpace.s4),
              _LinkChip(label: status, connected: connected),
            ],
          ),
        ),
        MecPress(
          child: FilledButton.icon(
            onPressed: onTriggerSos,
            style: FilledButton.styleFrom(
              backgroundColor: MecAlarm.color,
              // White on the alarm red measures 4.80 — the one status fill that
              // takes white ink rather than dark.
              foregroundColor: MecSurfaceDark.inkPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: const StadiumBorder(),
              minimumSize: const Size(0, 40),
            ).copyWith(overlayColor: mecStateLayer(MecSurfaceDark.inkPrimary)),
            icon: const Icon(Icons.sos_rounded, size: 16),
            label: Text(
              // The word, not a number: the header cannot see the configured
              // emergency line, and a hardcoded '911' beside a button that dials
              // something else would be actively misleading.
              'SOS',
              style: MecType.label.copyWith(
                color: MecSurfaceDark.inkPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: MecSpace.s8),
        MecPress(
          child: IconButton.filledTonal(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.person_outline, size: 20),
            tooltip: 'Settings',
          ),
        ),
      ],
    );
  }
}

/// Link state as an MD3 tonal pill: dot, plus the state in words.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.connected});

  final String label;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: connected ? c.containerFor(MecRiskBand.low.color) : c.elevated,
        borderRadius: BorderRadius.circular(MecRadius.chip),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? MecRiskBand.low.color : c.inkMuted,
            ),
          ),
          const SizedBox(width: MecSpace.s6),
          Text(
            label,
            style: MecType.axisTick.copyWith(
              color: connected ? c.inkPrimary : c.inkSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
