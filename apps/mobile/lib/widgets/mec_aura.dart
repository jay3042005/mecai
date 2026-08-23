/// Organic blurred shapes — Material You's signature background layer.
///
/// MD3 backgrounds are atmospheric rather than flat: large soft shapes, heavily
/// blurred, bleeding off-canvas. This paints them from the product palette so a
/// hero area has depth without a gradient sitting behind a number.
///
/// Two rules this holds to:
///
/// * **Static.** These shapes never move. docs/design.md §2 principle 3 says
///   motion means liveness or change, never decoration — a drifting blob behind
///   clinical data would be exactly that. Being static also means no reduced-motion
///   branch and no animation cost.
/// * **Invisible to everything but the eye.** Wrapped in `ExcludeSemantics` and
///   `IgnorePointer`, the equivalent of `aria-hidden`.
///
/// Opacity defaults are low on purpose. Behind a risk figure, use [subtle].
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// One blurred shape, positioned in fractions of the parent box.
@immutable
class MecBlob {
  const MecBlob({
    required this.color,
    required this.alignment,
    this.size = 0.7,
    this.circle = false,
  });

  final Color color;

  /// Where the shape's centre sits. Values outside -1..1 push it off-canvas,
  /// which is what gives the layer its "bleeding past the edge" quality.
  final Alignment alignment;

  /// Diameter as a fraction of the box's shortest side.
  final double size;

  /// Circle, or MD3's organic squircle with one tightened corner.
  final bool circle;
}

class MecAura extends StatelessWidget {
  const MecAura({
    super.key,
    required this.blobs,
    this.blur = 64,
    this.opacity = 0.18,
  });

  /// A restrained two-blob wash for use behind clinical content.
  ///
  /// Low enough that the numbers in front stay the loudest thing on screen.
  MecAura.subtle({Key? key, required Color accent})
      : this(
          key: key,
          opacity: 0.07,
          blobs: [
            MecBlob(color: accent, alignment: const Alignment(-0.9, -0.8)),
            MecBlob(color: accent, alignment: const Alignment(1.1, 0.9), size: 0.55),
          ],
        );

  final List<MecBlob> blobs;
  final double blur;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side = constraints.biggest.shortestSide;
                return Stack(
                  children: [
                    for (final b in blobs)
                      Align(
                        alignment: b.alignment,
                        child: Container(
                          width: side * b.size,
                          height: side * b.size,
                          decoration: BoxDecoration(
                            color: b.color,
                            shape: b.circle ? BoxShape.circle : BoxShape.rectangle,
                            borderRadius: b.circle
                                ? null
                                : const BorderRadius.only(
                                    topLeft: Radius.circular(100),
                                    bottomLeft: Radius.circular(100),
                                    bottomRight: Radius.circular(100),
                                    // One corner held back — the asymmetry is
                                    // what stops it reading as a plain pill.
                                    topRight: Radius.circular(24),
                                  ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
