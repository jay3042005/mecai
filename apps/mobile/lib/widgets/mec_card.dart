/// The Material You tonal card — one implementation, replacing nine.
///
/// Every surface in the app was hand-rolling the same
/// `Container(decoration: BoxDecoration(color: c.card, borderRadius: …, border:
/// Border.all(color: c.hairline)))`. This is that, plus the MD3 behaviour those
/// copies were missing: a state layer, press feedback, and a tonal variant for
/// clinical status.
///
/// Elevation here is a **hairline ring plus a surface step**, not a shadow
/// (docs/design.md §3.5) — so the card takes no `elevation` argument. The two
/// shadows the system does allow live in [MecElevation] and belong to floating
/// surfaces (sheets, dialogs, FABs), which Flutter draws for us.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_press.dart';

class MecCard extends StatelessWidget {
  const MecCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(MecSpace.s16),
    this.radius = MecRadius.card,
    this.surface,
    this.accent,
    this.border,
    this.semanticLabel,
  }) : status = null;

  /// A card tinted by a clinical status colour — an alert, an error, a success.
  ///
  /// The fill is the MD3 container recipe ([MecColors.containerFor]): the status
  /// hue at 12% over the card surface. Ink on it must stay [MecColors.inkPrimary]
  /// (15.1:1); the hue itself measures 4.15:1, which is fine for an icon but
  /// under AA for a label. Callers get that for free by not passing a text colour.
  const MecCard.status(
    Color this.status, {
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(MecSpace.s16),
    this.radius = MecRadius.card,
    this.semanticLabel,
  })  : surface = null,
        accent = null,
        border = null;

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Defaults to the card surface. Pass [MecColors.elevated] for a nested step.
  final Color? surface;

  /// Ink colour for the state layer and ripple. Defaults to the data hue.
  final Color? accent;

  final Color? border;

  /// Non-null for [MecCard.status].
  final Color? status;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final shape = BorderRadius.circular(radius);

    final fill = status != null ? c.containerFor(status!) : (surface ?? c.card);
    final edge = border ??
        (status != null ? status!.withValues(alpha: 0.25) : c.hairline);
    final ink = accent ?? status ?? c.series1;

    Widget content = Padding(padding: padding, child: child);

    if (onTap != null) {
      content = InkWell(
        onTap: onTap,
        borderRadius: shape,
        overlayColor: mecStateLayer(ink),
        child: content,
      );
    }

    Widget card = Material(
      color: fill,
      borderRadius: shape,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: shape,
          border: Border.all(color: edge),
        ),
        child: content,
      ),
    );

    if (semanticLabel != null) {
      card = Semantics(label: semanticLabel, container: true, child: card);
    }

    return onTap == null ? card : MecPress(child: card);
  }
}
