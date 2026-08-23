/// The MEC-AI watch prototype, drawn rather than photographed.
///
/// The pairing flow used to show `Icons.watch_outlined` — a generic round
/// smartwatch that looks nothing like the thing in the user's hand. This paints
/// the actual prototype: the rounded blue enclosure, the silkscreened wordmark,
/// the ST7789 panel in its white frame, the PPG window, the three tactile
/// buttons along the bottom edge, the two diagonal mounting posts, and the four
/// strap lugs. When the guide says "press any button", the user can see which
/// buttons it means.
///
/// ### Why it is painted and not an asset
///
/// The display is a live child widget ([screen]), so the panel can show the same
/// thing the firmware shows — boot wordmark, `BLE:OK`, the health HUD — and
/// change as the pairing flow advances. A PNG could not do that, and would need
/// three densities and a dark-mode variant besides.
///
/// ### Palette
///
/// The printed shell is a cyan-leaning blue; the shell here is built from
/// [MecSequential.blue] instead, because docs/design.md forbids a hex that is not
/// a token and the ramp reads as the same object. Pass [shell] to override if the
/// literal filament colour is ever wanted.
///
/// The render's brass inserts are drawn as **steel** for the same reason: the one
/// palette hue close to brass is the Moderate risk amber, and a reserved clinical
/// status colour must not appear as decoration on a device illustration.
///
/// Nothing here animates on its own. Movement is the caller's to drive, via
/// [backlight] and [pressedButton], so this widget needs no reduced-motion branch.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// The prototype's proportions, measured off the CAD render and expressed as
/// fractions of the enclosure's **width**, origin at its top-left corner.
///
/// One place to edit if the shell is re-cut.
abstract final class MecWatchGeometry {
  /// Enclosure height. 390 × 280 in the render.
  static const double bodyHeight = 0.718;
  static const double bodyCorner = 0.075;

  /// How far a strap lug clears the enclosure. The bottom pair reaches further
  /// because those lugs angle away from the wrist.
  static const double lugAbove = 0.060;
  static const double lugBelow = 0.100;
  static const double lugWidth = 0.052;
  static const double lugCorner = 0.014;
  static const List<double> lugLeft = <double>[0.232, 0.622];

  /// Full canvas, both lug pairs included, as a fraction of the width.
  static const double canvasHeight = lugAbove + bodyHeight + lugBelow;

  /// The silkscreened wordmark, directly above the display.
  static const Rect wordmark = Rect.fromLTRB(0.325, 0.028, 0.960, 0.186);

  /// White display frame, its thickness, and its corner.
  static const Rect bezel = Rect.fromLTRB(0.315, 0.192, 0.956, 0.5683);
  static const double bezelFrame = 0.018;
  static const double bezelCorner = 0.026;

  /// The active panel — an ST7789 1.14" at 240 × 135, so exactly 16:9. The
  /// numbers above are chosen to make this come out at that ratio.
  static const Rect panel = Rect.fromLTRB(0.333, 0.210, 0.938, 0.5503);

  /// Panel aspect, so a caller can lay out screen content at native resolution.
  static const Size panelPixels = Size(240, 135);

  /// The PPG sensor window on the left face.
  static const Offset sensor = Offset(0.141, 0.251);
  static const double sensorRing = 0.044;
  static const double sensorWell = 0.026;

  /// The two diagonal mounting posts.
  static const List<Offset> posts = <Offset>[
    Offset(0.069, 0.082),
    Offset(0.908, 0.644),
  ];
  static const double postRecess = 0.077;
  static const double postInsert = 0.034;

  /// The three tactile buttons along the bottom edge.
  static const List<double> buttonLeft = <double>[0.226, 0.436, 0.646];
  static const double buttonWidth = 0.108;
  static const double buttonTop = 0.590;
  static const double buttonHeight = 0.089;
  static const double buttonCorner = 0.014;

  /// Where the panel lands on a canvas [width] wide, in canvas coordinates.
  static Rect panelRect(double width) => Rect.fromLTRB(
        panel.left * width,
        (panel.top + lugAbove) * width,
        panel.right * width,
        (panel.bottom + lugAbove) * width,
      );
}

/// Short alias for [MecWatchGeometry] — the painter below reads better with
/// it, and Dart permits static access through a type alias.
typedef _G = MecWatchGeometry;

class MecWatchDevice extends StatelessWidget {
  const MecWatchDevice({
    super.key,
    required this.width,
    this.screen,
    this.backlight = 1,
    this.pressedButton,
    this.shell,
    this.glowTint,
    this.semanticLabel = 'MEC-AI watch',
  });

  /// Enclosure width. Everything else derives from it.
  final double width;

  /// Rendered inside the panel, at its native 240 × 135. Usually [MecWatchFace].
  final Widget? screen;

  /// 0 = panel dark, 1 = lit. Drives the panel's own bloom onto the shell.
  final double backlight;

  /// Index into [MecWatchGeometry.buttonLeft], drawn depressed. Null for none.
  final int? pressedButton;

  /// Overrides the shell hue. Defaults to a two-stop pull down the blue ramp.
  final Color? shell;

  /// The bloom's colour. Defaults to the data hue.
  final Color? glowTint;

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final size = Size(width, width * MecWatchGeometry.canvasHeight);
    final panel = MecWatchGeometry.panelRect(width);

    return Semantics(
      label: semanticLabel,
      image: true,
      child: ExcludeSemantics(
        child: SizedBox.fromSize(
          size: size,
          child: Stack(
            children: [
              CustomPaint(
                size: size,
                painter: _ShellPainter(
                  shell: shell,
                  backlight: backlight.clamp(0.0, 1.0),
                  glowTint: glowTint ?? MecSeries.s1Dark,
                  pressedButton: pressedButton,
                ),
              ),
              if (screen != null)
                Positioned.fromRect(
                  rect: panel,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      MecWatchGeometry.bezelCorner * width * 0.5,
                    ),
                    child: Opacity(
                      // The panel fades with the backlight rather than switching
                      // off, so a wake reads as a ramp and not a cut.
                      opacity: (0.15 + 0.85 * backlight).clamp(0.0, 1.0),
                      child: screen,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellPainter extends CustomPainter {
  const _ShellPainter({
    required this.shell,
    required this.backlight,
    required this.glowTint,
    required this.pressedButton,
  });

  final Color? shell;
  final double backlight;
  final Color glowTint;
  final int? pressedButton;

  static const Color _lugInk = MecSurfaceDark.page;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // Body origin sits below the top lug pair; every geometry constant is
    // relative to the body, so translate once and forget about it.
    canvas.save();
    canvas.translate(0, _G.lugAbove * w);

    _lugs(canvas, w);
    _body(canvas, w);
    _posts(canvas, w);
    _sensor(canvas, w);
    _buttons(canvas, w);
    _wordmark(canvas, w);
    _display(canvas, w);

    canvas.restore();
  }

  /// Four strap lugs, drawn before the body so their inner ends tuck under it.
  void _lugs(Canvas canvas, double w) {
    final paint = Paint()..color = _lugInk;
    final radius = Radius.circular(_G.lugCorner * w);

    for (final left in _G.lugLeft) {
      // Top pair: from above the body down into it.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left * w,
            -_G.lugAbove * w,
            _G.lugWidth * w,
            (_G.lugAbove + 0.06) * w,
          ),
          radius,
        ),
        paint,
      );
      // Bottom pair, offset outward by a hair — the render's lugs splay.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            (left + 0.008) * w,
            (_G.bodyHeight - 0.02) * w,
            _G.lugWidth * w,
            (_G.lugBelow + 0.02) * w,
          ),
          radius,
        ),
        paint,
      );
    }
  }

  /// The enclosure: a tonal pull down the blue ramp, lit from above, with a
  /// hairline along the top edge that does the work a bevel would.
  void _body(Canvas canvas, double w) {
    final rect = Rect.fromLTWH(0, 0, w, _G.bodyHeight * w);
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(_G.bodyCorner * w),
    );

    final top = shell ?? MecSequential.blue[7];
    final bottom = shell != null
        ? Color.lerp(shell!, MecSurfaceDark.page, 0.28)!
        : MecSequential.blue[10];

    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[top, bottom],
        ).createShader(rect),
    );

    // The panel's own light spilling onto the shell. Only while lit, and never
    // strong enough to read as a gradient behind data.
    if (backlight > 0.02) {
      final bloom = _G.bezel.inflate(0.03);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            bloom.left * w,
            bloom.top * w,
            bloom.right * w,
            bloom.bottom * w,
          ),
          Radius.circular(_G.bezelCorner * w * 2),
        ),
        Paint()
          ..color = glowTint.withValues(alpha: 0.30 * backlight)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.055 * w),
      );
    }

    canvas.drawRRect(
      shape.deflate(0.004 * w),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.007 * w
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            MecSurfaceDark.inkPrimary.withValues(alpha: 0.28),
            MecSurfaceDark.inkPrimary.withValues(alpha: 0.02),
          ],
        ).createShader(rect),
    );
  }

  /// Two diagonal mounting posts: a lighter machined recess, a steel insert, and
  /// a slot so it reads as a screw rather than a dot.
  void _posts(Canvas canvas, double w) {

    for (final p in _G.posts) {
      final center = Offset(p.dx * w, p.dy * w);

      canvas.drawCircle(
        center,
        _G.postRecess * w,
        Paint()
          ..color = (shell == null
                  ? MecSequential.blue[5]
                  : Color.lerp(shell!, MecSurfaceDark.inkPrimary, 0.22)!)
              .withValues(alpha: 0.75),
      );
      canvas.drawCircle(
        center,
        _G.postInsert * w,
        Paint()..color = MecSurfaceDark.baseline,
      );
      canvas.drawCircle(
        center,
        _G.postInsert * w,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.006 * w
          ..color = MecSurfaceDark.inkMuted.withValues(alpha: 0.7),
      );
      canvas.drawLine(
        center - Offset(_G.postInsert * w * 0.55, 0),
        center + Offset(_G.postInsert * w * 0.55, 0),
        Paint()
          ..strokeWidth = 0.008 * w
          ..color = MecSurfaceDark.page.withValues(alpha: 0.65),
      );
    }
  }

  /// The PPG window — white retaining ring, dark optic.
  void _sensor(Canvas canvas, double w) {
    final center = Offset(_G.sensor.dx * w, _G.sensor.dy * w);

    canvas.drawCircle(
      center,
      _G.sensorRing * w,
      Paint()..color = MecSurfaceDark.inkPrimary.withValues(alpha: 0.92),
    );
    canvas.drawCircle(
      center,
      _G.sensorWell * w,
      Paint()..color = MecSurfaceDark.page,
    );
  }

  /// Three tactile buttons. The pressed one sinks and loses its top highlight,
  /// which is the whole reason this widget takes a `pressedButton` at all.
  void _buttons(Canvas canvas, double w) {

    for (var i = 0; i < _G.buttonLeft.length; i++) {
      final down = pressedButton == i;
      final rect = Rect.fromLTWH(
        _G.buttonLeft[i] * w,
        (_G.buttonTop + (down ? 0.006 : 0)) * w,
        _G.buttonWidth * w,
        (_G.buttonHeight - (down ? 0.006 : 0)) * w,
      );
      final shape = RRect.fromRectAndRadius(
        rect,
        Radius.circular(_G.buttonCorner * w),
      );

      canvas.drawRRect(
        shape,
        Paint()
          ..color = down
              ? Color.alphaBlend(
                  glowTint.withValues(alpha: 0.35),
                  MecSurfaceDark.page,
                )
              : MecSurfaceDark.page,
      );
      if (!down) {
        canvas.drawLine(
          rect.topLeft + Offset(_G.buttonCorner * w, 0.006 * w),
          rect.topRight + Offset(-_G.buttonCorner * w, 0.006 * w),
          Paint()
            ..strokeWidth = 0.006 * w
            ..strokeCap = StrokeCap.round
            ..color = MecSurfaceDark.inkPrimary.withValues(alpha: 0.16),
        );
      }
    }
  }

  /// "MEC-AI", silkscreened. Laid out to fill its measured rect so the letter
  /// size tracks the device rather than being a second magic number.
  void _wordmark(Canvas canvas, double w) {
    final box = Rect.fromLTRB(
      _G.wordmark.left * w,
      _G.wordmark.top * w,
      _G.wordmark.right * w,
      _G.wordmark.bottom * w,
    );

    final painter = TextPainter(
      text: TextSpan(
        text: 'MEC-AI',
        style: TextStyle(
          fontFamily: MecType.family,
          color: MecSurfaceDark.inkPrimary,
          fontSize: box.height * 0.94,
          fontWeight: FontWeight.w800,
          letterSpacing: box.height * 0.06,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Fit to the silkscreen area, whatever the platform's fallback font metrics.
    final scale = (box.width / painter.width).clamp(0.0, 1.0);
    canvas.save();
    canvas.translate(
      box.left + (box.width - painter.width * scale) / 2,
      box.top + (box.height - painter.height * scale) / 2,
    );
    canvas.scale(scale);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  /// White frame plus the dark well the panel sits in. The [MecWatchDevice]
  /// child paints over the well.
  void _display(Canvas canvas, double w) {

    final bezel = Rect.fromLTRB(
      _G.bezel.left * w,
      _G.bezel.top * w,
      _G.bezel.right * w,
      _G.bezel.bottom * w,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bezel, Radius.circular(_G.bezelCorner * w)),
      Paint()..color = MecSurfaceDark.inkPrimary.withValues(alpha: 0.94),
    );

    final panel = Rect.fromLTRB(
      _G.panel.left * w,
      _G.panel.top * w,
      _G.panel.right * w,
      _G.panel.bottom * w,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        panel,
        Radius.circular(_G.bezelCorner * w * 0.5),
      ),
      Paint()..color = MecSurfaceDark.page,
    );
  }

  @override
  bool shouldRepaint(_ShellPainter old) =>
      old.shell != shell ||
      old.backlight != backlight ||
      old.glowTint != glowTint ||
      old.pressedButton != pressedButton;
}
