/// Floating bottom navigation.
///
/// A detached pill rather than an edge-anchored `NavigationBar`, so the page
/// scrolls visibly beneath it — on a monitoring screen the last chart row staying
/// partly visible tells the reader there is more below.
///
/// ### Why the destinations carry a word and not only an icon
///
/// Same reasoning as the risk band (docs/design.md §4): an icon alone is one
/// channel. A heart glyph and a droplet glyph at 22px are easy to confuse at a
/// glance, and this is the control someone reaches for while worried about a
/// reading. Labels stay visible on every destination rather than only the selected
/// one, which is MD3's `NavigationDestinationLabelBehavior.alwaysShow`.
///
/// ### Motion
///
/// The selected pill slides between destinations. Under reduced motion it jumps —
/// docs/design.md §3.6 treats sliding chrome as a vestibular trigger, and the
/// indicator's job (showing which page you are on) is fully carried by its
/// position, not by the travel.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_press.dart';

@immutable
class MecNavDestination {
  const MecNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Unread/active count, e.g. live alerts. Zero hides the badge.
  final int badgeCount;
}

class MecBottomNav extends StatelessWidget {
  const MecBottomNav({
    super.key,
    required this.destinations,
    required this.currentIndex,
    required this.onSelect,
  });

  final List<MecNavDestination> destinations;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// Height of the bar itself, excluding the gap below it. Screens add
  /// [reservedHeight] of bottom padding so content can scroll clear of it.
  static const double barHeight = 64;

  /// Bottom padding a scrolling page needs so its last item clears the bar.
  static const double reservedHeight = barHeight + MecSpace.s24 + MecSpace.s16;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MecSpace.s16,
        0,
        MecSpace.s16,
        MecSpace.s16,
      ),
      child: Container(
        height: barHeight,
        decoration: BoxDecoration(
          color: c.elevated,
          borderRadius: BorderRadius.circular(MecRadius.hero),
          border: Border.all(color: c.hairline),
          boxShadow: [
            // Lifts the bar off the content it overlaps. Without it the pill reads
            // as part of the page rather than floating above it.
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final slotWidth = constraints.maxWidth / destinations.length;

            return Stack(
              children: [
                // The travelling indicator, behind the labels.
                AnimatedPositioned(
                  duration: context.stilled(MecMotion.fast),
                  curve: MecEasing.standard,
                  left: slotWidth * currentIndex,
                  top: 0,
                  bottom: 0,
                  width: slotWidth,
                  child: Center(
                    child: Container(
                      height: barHeight - MecSpace.s16,
                      margin: const EdgeInsets.symmetric(horizontal: MecSpace.s6),
                      decoration: BoxDecoration(
                        color: c.series1.withValues(alpha: MecState.press),
                        borderRadius: BorderRadius.circular(MecRadius.pill),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      Expanded(
                        child: _Destination(
                          destination: destinations[i],
                          selected: i == currentIndex,
                          onTap: () => onSelect(i),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  const _Destination({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final MecNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final tint = selected ? c.series1 : c.inkSecondary;

    return MecPress(
      child: InkWell(
        onTap: onTap,
        // The whole slot is the target, not just the glyph — an icon-sized hit
        // area on a bar someone taps while walking is a miss waiting to happen.
        child: Semantics(
          selected: selected,
          button: true,
          label: destination.label,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Badge(
                isLabelVisible: destination.badgeCount > 0,
                label: Text('${destination.badgeCount}'),
                backgroundColor: MecRiskBand.high.color,
                child: Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 22,
                  color: tint,
                ),
              ),
              const SizedBox(height: MecSpace.s2),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MecType.label.copyWith(
                  color: tint,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
