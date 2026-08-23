/// The pairing screen's hero — the user's own watch, inside the boot animation's
/// rings.
///
/// It used to be `Icons.watch_outlined`: a round consumer smartwatch that shares
/// nothing with the MEC-AI prototype. It is now [MecWatchDevice], with the real
/// panel content ([MecWatchFace]) behind the glass, sitting inside the same
/// concentric rings the splash opens with ([MecRingBurst]) run as a radar. So the
/// screen shows the user the object on their wrist and the screen they are about
/// to see on it.
///
/// The rings still carry the state without a word:
///
/// * **searching** — full [MecBootPalette.calm] sweep, rings racing outward. The
///   alarm red is absent on purpose; a red pulse during a scan would read as a
///   failure that has not happened.
/// * **closing** — `settle` ramps toward 1, draining colour out of the rings and
///   into the data blue as the connection firms up. Certainty, as saturation.
/// * **success** — rings stop, the watch lifts, sparkles fire **once**.
/// * **error** — nothing moves, and the panel goes to the firmware's `BLE:--`.
///   A failure is not a thing to animate.
///
/// Every loop is gated on reduced motion, where the hero holds a still watch and
/// a still panel and the surrounding checklist carries the state instead.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_aura.dart';
import 'mec_boot_fx.dart';
import 'mec_watch_device.dart';
import 'mec_watch_face.dart';

/// What the rings are depicting. Deliberately coarser than the screen's step
/// machine, so the screen can re-sequence its steps without touching the art.
enum PairHeroPhase { idle, searching, closing, success, error }

class PairHero extends StatefulWidget {
  const PairHero({
    super.key,
    required this.phase,
    required this.face,
    this.settle = 0,
    this.size = 220,
    this.highlightButton,
  });

  final PairHeroPhase phase;

  /// What the panel shows. Driven by the guide step on the welcome screen and by
  /// the connection stage once the flow is running.
  final MecWatchFaceMode face;

  /// 0 = full palette, 1 = fully drained to the data hue. Only read while
  /// [PairHeroPhase.closing].
  final double settle;

  /// Box **width**. The box is `size × size * heightRatio`.
  final double size;

  /// A tactile button to call out — the one the guide is telling the user to
  /// press. Depresses once on arrival, then stays lit.
  final int? highlightButton;

  /// Height of the hero box as a fraction of [size]. Enough headroom for the
  /// radar to clear the enclosure on every side.
  static const double heightRatio = 0.9;

  /// The enclosure's width as a fraction of [size].
  static const double _deviceRatio = 0.72;

  @override
  State<PairHero> createState() => _PairHeroState();
}

class _PairHeroState extends State<PairHero> with TickerProviderStateMixin {
  /// Drives the outward radar sweep. Repeats while the phase is live.
  late final AnimationController _radar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  /// Drives whatever the panel itself has moving — range arcs, scan sweep, the
  /// link progress rule. Separate from the radar so the two can differ in tempo.
  late final AnimationController _panel = AnimationController(
    vsync: this,
    duration: MecMotion.ambient,
  );

  /// One pass, on success only.
  late final AnimationController _sparkle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// The watch lifting as the link lands.
  late final AnimationController _land = AnimationController(
    vsync: this,
    duration: MecMotion.fast,
  );

  /// A single press-and-release on the button the guide is pointing at.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  bool get _live =>
      widget.phase == PairHeroPhase.searching ||
      widget.phase == PairHeroPhase.closing;

  /// True for the faces that have something moving in them.
  bool get _panelMoves => switch (widget.face) {
        MecWatchFaceMode.proximity ||
        MecWatchFaceMode.scanning ||
        MecWatchFaceMode.linking =>
          true,
        _ => false,
      };

  /// Panel brightness. Asleep is dark; a failed link dims rather than blacks out.
  double get _backlight => switch (widget.face) {
        MecWatchFaceMode.asleep => 0.0,
        MecWatchFaceMode.offline => 0.45,
        _ => 1.0,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PairHero old) {
    super.didUpdateWidget(old);
    if (old.phase != widget.phase ||
        old.face != widget.face ||
        old.highlightButton != widget.highlightButton) {
      _sync();
    }
  }

  void _sync() {
    final reduced = context.reduceMotion;

    _loop(_radar, run: _live && !reduced);
    _loop(_panel, run: _panelMoves && !reduced);

    if (widget.phase == PairHeroPhase.success) {
      // Under reduced motion the watch is simply landed; it does not lift and
      // the sparkles never run.
      if (reduced) {
        _land.value = 1;
      } else {
        if (_land.status == AnimationStatus.dismissed) _land.forward();
        if (_sparkle.status == AnimationStatus.dismissed) _sparkle.forward();
      }
    } else {
      _land.value = 0;
      _sparkle.value = 0;
    }

    // A press is a demonstration, not decoration — but it is still movement, so
    // reduced motion gets the button held down instead of pressing.
    if (widget.highlightButton != null) {
      if (reduced) {
        _press.value = 1;
      } else if (_press.status == AnimationStatus.dismissed) {
        _press.forward().then((_) {
          if (mounted) _press.reverse();
        });
      }
    } else {
      _press.value = 0;
    }
  }

  void _loop(AnimationController c, {required bool run}) {
    if (run) {
      if (!c.isAnimating) c.repeat();
    } else if (c.isAnimating) {
      c.stop();
      c.value = 0;
    }
  }

  @override
  void dispose() {
    _radar.dispose();
    _panel.dispose();
    _sparkle.dispose();
    _land.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final tint = switch (widget.phase) {
      PairHeroPhase.success => MecRiskBand.low.color,
      PairHeroPhase.error => MecRiskBand.high.color,
      _ => c.series1,
    };

    final box = Size(widget.size, widget.size * PairHero.heightRatio);
    final deviceWidth = widget.size * PairHero._deviceRatio;

    return SizedBox.fromSize(
      size: box,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          MecAura.subtle(accent: tint),

          // The radar. Same painter as the splash's opening burst, sized so the
          // outermost ring clears the enclosure on every side.
          if (_live)
            AnimatedBuilder(
              animation: _radar,
              builder: (context, _) => TweenAnimationBuilder<double>(
                tween: Tween<double>(end: widget.settle),
                duration: MecMotion.value,
                curve: MecEasing.standard,
                builder: (context, settle, _) => MecRingBurst(
                  progress: _radar.value,
                  palette: MecBootPalette.calm,
                  ringCount: 6,
                  spacing: 0.16,
                  strokeWidth: 2,
                  maxRadiusFactor: 0.45,
                  settle: settle,
                  settleColor: c.series1,
                ),
              ),
            ),

          if (widget.phase == PairHeroPhase.success)
            AnimatedBuilder(
              animation: _sparkle,
              builder: (context, _) => MecSparkleField(
                progress: _sparkle.value,
                count: 16,
                area: const Rect.fromLTWH(0.02, 0.05, 0.96, 0.9),
              ),
            ),

          _device(deviceWidth, tint),
        ],
      ),
    );
  }

  /// The enclosure, lifting a few pixels as the link lands.
  Widget _device(double deviceWidth, Color tint) => AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_land, _press, _panel]),
        builder: (context, _) {
          final lift = Curves.easeOutBack.transform(_land.value);

          return Transform.translate(
            offset: Offset(0, -lift * deviceWidth * 0.03),
            child: Transform.scale(
              scale: 1 + lift * 0.03,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: _backlight),
                duration: MecMotion.value,
                curve: MecEasing.standard,
                builder: (context, backlight, _) => MecWatchDevice(
                  width: deviceWidth,
                  backlight: backlight,
                  glowTint: tint,
                  pressedButton:
                      _press.value > 0.5 ? widget.highlightButton : null,
                  screen: MecWatchFace(
                    mode: widget.face,
                    pulse: _panel.value,
                  ),
                ),
              ),
            ),
          );
        },
      );
}
