/// What the watch's panel is showing, drawn at the panel's native resolution.
///
/// Every face here is a transcription of something `MEC-AI3/MEC-AI3.ino` really
/// puts on the ST7789 — the boot wordmark with `BLE: MECAI-Watch` beneath it, the
/// `BLE:OK` / `BLE:--` corner flag, the rule at y=28, the mode dots at y=128.
/// That is the point: the setup guide tells the user what they will see on the
/// watch, so it should show them the same pixels.
///
/// The faces are laid out in a fixed 240 × 135 box — the panel's real geometry —
/// and scaled to fit by [MecWatchFace] itself. Coordinates below can therefore be
/// read straight off the firmware.
///
/// ### Honesty
///
/// No face invents a reading. Where the firmware would print a number it prints
/// `--`, exactly as the real device does before it has a measurement. A mocked-up
/// heart rate on a medical device illustration would be the wrong kind of polish.
///
/// Motion is the caller's: [pulse] is a 0→1 loop the caller stops under reduced
/// motion, so this widget has no timers and no reduced-motion branch.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// The panel states the pairing flow needs, in the order the user meets them.
enum MecWatchFaceMode {
  /// Powered off. A dark panel with the faintest sheen.
  asleep,

  /// The firmware's boot screen: wordmark, then the advertised BLE name.
  boot,

  /// Bluetooth is up and advertising. `BLE:OK`, waiting to be found.
  advertising,

  /// Range guidance for the "keep the watch nearby" step.
  proximity,

  /// Armed and idle on the health HUD, values still `--`.
  standby,

  /// The phone is scanning; the panel sweeps.
  scanning,

  /// Link negotiation, shown as the firmware's progress rule filling.
  linking,

  /// Paired and streaming.
  linked,

  /// No link. The firmware's `BLE:--`.
  offline,
}

/// The panel, at 240 × 135, scaled into whatever box it is given.
class MecWatchFace extends StatelessWidget {
  const MecWatchFace({super.key, required this.mode, this.pulse = 0});

  final MecWatchFaceMode mode;

  /// A 0→1 loop for the faces that move. Hold at 0 for a still panel.
  final double pulse;

  static const Size _panel = Size(240, 135);

  // The firmware's palette, as tokens. Cyan on the device is the data blue here;
  // ST77XX_GREEN and ST77XX_RED are the clinical status pair.
  static const Color _ink = MecSurfaceDark.inkPrimary;
  static const Color _dim = MecSurfaceDark.inkMuted;
  static Color get _data => MecSeries.s2Dark;
  static Color get _ok => MecRiskBand.low.color;
  static Color get _bad => MecRiskBand.high.color;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: _panel.width,
        height: _panel.height,
        child: ColoredBox(
          color: MecSurfaceDark.page,
          child: Stack(children: _layers()),
        ),
      ),
    );
  }

  List<Widget> _layers() => switch (mode) {
        MecWatchFaceMode.asleep => const <Widget>[],
        MecWatchFaceMode.boot => _boot(),
        MecWatchFaceMode.advertising => _hud(link: _LinkFlag.ok, caption: 'ADVERTISING'),
        MecWatchFaceMode.proximity => _proximity(),
        MecWatchFaceMode.standby => _hud(link: _LinkFlag.ok, caption: 'READY TO PAIR'),
        MecWatchFaceMode.scanning => _hud(
            link: _LinkFlag.ok,
            caption: 'WAITING FOR PHONE',
            sweep: true,
          ),
        MecWatchFaceMode.linking => _hud(
            link: _LinkFlag.ok,
            caption: 'LINKING',
            progress: pulse,
          ),
        MecWatchFaceMode.linked => _hud(
            link: _LinkFlag.ok,
            caption: 'MONITORING',
            live: true,
          ),
        MecWatchFaceMode.offline => _hud(link: _LinkFlag.down, caption: 'NO LINK'),
      };

  // ── boot ──────────────────────────────────────────────────────────────
  // Firmware: wordmark centred at size 4, then "BLE: MECAI-Watch" at y=115.

  List<Widget> _boot() => <Widget>[
        Positioned(
          left: 0,
          right: 0,
          top: 34,
          child: Center(
            child: Text(
              'MEC-AI',
              style: _mono(30, weight: FontWeight.w800).copyWith(
                letterSpacing: 2,
                shadows: <Shadow>[
                  Shadow(color: _data.withValues(alpha: 0.55), blurRadius: 12),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 106,
          child: Center(
            child: Text(
              'BLE: MECAI-Watch',
              style: _mono(11, color: _data),
            ),
          ),
        ),
      ];

  // ── proximity ─────────────────────────────────────────────────────────
  // Not a firmware screen: the range hint the setup guide needs. Arcs widen
  // with `pulse`, which is the one thing on this face that means anything.

  List<Widget> _proximity() => <Widget>[
        Positioned.fill(
          child: CustomPaint(painter: _RangePainter(pulse: pulse, tint: _data)),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 46,
          child: Center(
            child: Text('< 1 m', style: _mono(30, weight: FontWeight.w700)),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 106,
          child: Center(
            child: Text('KEEP WATCH CLOSE', style: _mono(11, color: _dim)),
          ),
        ),
      ];

  // ── the health HUD ────────────────────────────────────────────────────
  // The firmware's own layout: wear flag top-left, BLE flag top-right, rule at
  // y=28, HEART RATE / SpO2 columns, rule at y=93, caption at y=106, mode dots
  // at y=128.

  List<Widget> _hud({
    required _LinkFlag link,
    required String caption,
    bool sweep = false,
    bool live = false,
    double? progress,
  }) =>
      <Widget>[
        if (sweep)
          Positioned.fill(
            child: CustomPaint(painter: _SweepPainter(pulse: pulse, tint: _data)),
          ),

        Positioned(
          left: 7,
          top: 8,
          child: Text(
            live ? '* WORN' : '* OFF',
            style: _mono(11, color: live ? _ok : _dim),
          ),
        ),
        Positioned(
          right: 7,
          top: 8,
          child: Text(
            link == _LinkFlag.ok ? 'BLE:OK' : 'BLE:--',
            style: _mono(
              11,
              color: switch (link) {
                _LinkFlag.ok => _data,
                _LinkFlag.down => _bad,
              },
            ),
          ),
        ),
        _rule(28),

        _column(left: 14, label: 'HEART RATE', tint: _bad, unit: 'BPM', live: live),
        _column(left: 138, label: 'SpO2', tint: _data, unit: '%', live: live),

        if (progress == null)
          _rule(93)
        else
          Positioned(
            left: 5,
            top: 91,
            child: Row(
              children: <Widget>[
                Container(width: 230 * progress.clamp(0.0, 1.0), height: 3, color: _data),
                Container(
                  width: 230 * (1 - progress.clamp(0.0, 1.0)),
                  height: 3,
                  color: MecSurfaceDark.baseline,
                ),
              ],
            ),
          ),

        Positioned(
          left: 0,
          right: 0,
          top: 102,
          child: Center(child: Text(caption, style: _mono(11, color: _ink))),
        ),
        Positioned(left: 0, right: 0, top: 122, child: _modeDots()),
      ];

  /// One vital column: red/blue label, the value, the unit beside it.
  Widget _column({
    required double left,
    required String label,
    required Color tint,
    required String unit,
    required bool live,
  }) =>
      Positioned(
        left: left,
        top: 36,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: _mono(10, color: tint)),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                // `--` until the watch has a measurement, which is what the
                // device shows and therefore what the guide should show.
                Text('--', style: _mono(30, weight: FontWeight.w700)),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(unit, style: _mono(10, color: _dim)),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _rule(double top) => Positioned(
        left: 5,
        right: 5,
        top: top,
        child: Container(height: 1, color: MecSurfaceDark.baseline),
      );

  /// The firmware's two mode dots, 12px apart, the active one filled.
  Widget _modeDots() => Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < 2; i++)
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == 0 ? _data : Colors.transparent,
                  border: Border.all(color: i == 0 ? _data : _dim),
                ),
              ),
          ],
        ),
      );

  /// The GFX default font is a 6×8 monospace cell; tabular figures are the
  /// closest the type scale gets to it.
  TextStyle _mono(double size, {Color color = _ink, FontWeight? weight}) =>
      MecType.axisTick.copyWith(
        fontSize: size,
        color: color,
        fontWeight: weight ?? FontWeight.w500,
        height: 1,
      );
}

enum _LinkFlag { ok, down }

/// Range arcs for the proximity face — three arcs sweeping outward.
class _RangePainter extends CustomPainter {
  const _RangePainter({required this.pulse, required this.tint});

  final double pulse;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.95);

    for (var i = 0; i < 3; i++) {
      final t = ((pulse + i / 3) % 1.0);
      canvas.drawCircle(
        origin,
        size.height * (0.25 + t * 0.85),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tint.withValues(alpha: (1 - t) * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_RangePainter old) => old.pulse != pulse;
}

/// A single soft band travelling down the panel while the phone scans.
class _SweepPainter extends CustomPainter {
  const _SweepPainter({required this.pulse, required this.tint});

  final double pulse;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    if (pulse <= 0) return;

    // Eased so the band lingers at the edges rather than snapping around.
    final y = size.height * (0.5 - 0.5 * math.cos(pulse * 2 * math.pi));
    final band = Rect.fromCenter(
      center: Offset(size.width / 2, y),
      width: size.width,
      height: size.height * 0.5,
    );

    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            tint.withValues(alpha: 0),
            tint.withValues(alpha: 0.16),
            tint.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.pulse != pulse;
}
