/// The pairing flow's presentational pieces: the setup guide's pages, the live
/// progress rail, the page dots, and the two outcome cards.
///
/// Split out of `pair_watch_screen.dart` so the screen holds the state machine
/// and nothing else, and so every surface here picks up [MecCard]'s tonal fill
/// and state layer instead of re-declaring a decoration.
///
/// The guide is **paged, not stacked**. Four cards in a column ran off the bottom
/// of a 640dp phone and the screen scrolled — so the step the user needed to read
/// first shared the viewport with the button they were meant to press last. One
/// card at a time is a fixed height, which is what lets the whole flow fit, and it
/// gives each step room for the hero to illustrate it.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_card.dart';
import 'mec_watch_face.dart';

/// One step of the pre-connection guide, with the panel state that illustrates it.
@immutable
class PairGuideStep {
  const PairGuideStep({
    required this.icon,
    required this.title,
    required this.detail,
    required this.face,
    this.highlightButton,
  });

  final IconData icon;
  final String title;
  final String detail;

  /// What the hero's watch shows while this step is on screen.
  final MecWatchFaceMode face;

  /// A tactile button for the hero to call out, if this step names one.
  final int? highlightButton;
}

/// The guide copy. Lives beside the widget that renders it so the two stay in
/// step, and beside the faces so a new step cannot forget its illustration.
///
/// The wording of what appears on the watch is taken from the firmware, not
/// paraphrased: `MEC-AI3/MEC-AI3.ino` prints `BLE: MECAI-Watch` on boot and
/// `BLE:OK` in the corner once a phone is attached.
const pairGuideSteps = <PairGuideStep>[
  PairGuideStep(
    icon: Icons.power_settings_new,
    title: 'Power on the watch',
    detail: 'Press any of the three buttons to wake it. The panel shows the '
        'MEC-AI logo, then "BLE: MECAI-Watch".',
    face: MecWatchFaceMode.boot,
    highlightButton: 0,
  ),
  PairGuideStep(
    icon: Icons.bluetooth,
    title: 'Turn on phone Bluetooth',
    detail: 'Open your phone’s quick settings and switch Bluetooth on. The '
        'watch shows "BLE:OK" once it is advertising.',
    face: MecWatchFaceMode.advertising,
  ),
  PairGuideStep(
    icon: Icons.straighten,
    title: 'Keep the watch close',
    detail: 'Hold it within one metre of this phone while pairing. Move closer '
        'if the scan takes more than a few seconds.',
    face: MecWatchFaceMode.proximity,
  ),
  PairGuideStep(
    icon: Icons.touch_app,
    title: 'Tap Scan & Connect',
    detail: 'The app finds the watch, pairs, and starts streaming heart rate, '
        'blood oxygen and temperature.',
    face: MecWatchFaceMode.standby,
  ),
];

/// One page of the guide: number, icon, title, detail.
///
/// Sized by its parent's viewport rather than its content, so paging never
/// changes the layout's height.
class PairGuidePage extends StatelessWidget {
  const PairGuidePage({
    super.key,
    required this.index,
    required this.total,
    required this.step,
  });

  final int index;
  final int total;
  final PairGuideStep step;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return MecCard(
      padding: const EdgeInsets.all(MecSpace.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // The step number in an MD3 tonal container — ink stays inkPrimary,
              // since the hue itself is under AA for text this small.
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.accentContainer,
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: MecType.label.copyWith(
                      color: c.inkPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: MecSpace.s12),
              Icon(step.icon, size: 18, color: c.series1),
              const SizedBox(width: MecSpace.s8),
              Expanded(
                child: Text(
                  step.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MecType.label.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${index + 1}/$total',
                style: MecType.axisTick.copyWith(color: c.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Expanded(
            child: Text(
              step.detail,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: MecType.axisTick.copyWith(
                color: c.inkSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Page dots for the guide. Tappable, because a dot that only reports position
/// wastes a 24dp target the user is already looking at.
class PairStepDots extends StatelessWidget {
  const PairStepDots({
    super.key,
    required this.count,
    required this.index,
    required this.onTap,
  });

  final int count;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < count; i++)
          Semantics(
            label: 'Step ${i + 1} of $count',
            selected: i == index,
            button: true,
            child: InkWell(
              onTap: () => onTap(i),
              borderRadius: BorderRadius.circular(MecRadius.pill),
              overlayColor: mecStateLayer(c.series1),
              child: SizedBox(
                // Full 24dp target around a 6dp dot (WCAG 2.5.5).
                width: MecChart.minHitTarget,
                height: MecChart.minHitTarget,
                child: Center(
                  child: AnimatedContainer(
                    duration: context.stilled(MecMotion.fast),
                    curve: MecEasing.standard,
                    // The active dot stretches rather than only changing colour,
                    // so position survives a colour-blind read.
                    width: i == index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == index ? c.series1 : c.baseline,
                      borderRadius: BorderRadius.circular(MecRadius.pill),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One line of the live connection checklist.
///
/// State is carried by an icon *and* the label's weight and colour, never by
/// colour alone — the same rule the risk indicator follows. A hairline rail joins
/// the rows so the column reads as one sequence rather than six unrelated lines.
class PairStatusStep extends StatelessWidget {
  const PairStatusStep({
    super.key,
    required this.label,
    required this.isDone,
    required this.isActive,
    this.isLast = false,
  });

  final String label;
  final bool isDone;
  final bool isActive;

  /// Suppresses the rail below the final row.
  final bool isLast;

  static const double _rowHeight = 34;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return SizedBox(
      height: _rowHeight,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 20,
            child: Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                if (!isLast)
                  Positioned(
                    top: 18,
                    bottom: 0,
                    child: Container(
                      width: 1.5,
                      color: isDone ? MecRiskBand.low.color : c.gridline,
                    ),
                  ),
                SizedBox(
                  width: 20,
                  height: 20,
                  child: switch ((isDone, isActive)) {
                    (true, _) => Icon(
                        Icons.check_circle,
                        size: 18,
                        color: MecRiskBand.low.color,
                      ),
                    (false, true) => Padding(
                        padding: const EdgeInsets.all(2),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.series1,
                        ),
                      ),
                    (false, false) => Icon(
                        Icons.radio_button_unchecked,
                        size: 18,
                        color: c.inkMuted,
                      ),
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: MecSpace.s12),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: context.stilled(MecMotion.fast),
              curve: MecEasing.standard,
              style: MecType.body.copyWith(
                fontSize: 14,
                color: isDone
                    ? MecRiskBand.low.color
                    : isActive
                        ? c.inkPrimary
                        : c.inkMuted,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }

  /// Height of a checklist of [rows] rows, so the screen can budget for it
  /// without measuring.
  static double heightFor(int rows) => rows * _rowHeight;
}

/// Shown once the watch is paired and streaming.
class PairSuccessCard extends StatelessWidget {
  const PairSuccessCard({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecCard.status(
      MecRiskBand.low.color,
      padding: const EdgeInsets.all(MecSpace.s16),
      child: Row(
        children: <Widget>[
          Icon(Icons.favorite, size: 24, color: MecRiskBand.low.color),
          const SizedBox(width: MecSpace.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  'Streaming live vitals',
                  style: MecType.body.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: MecSpace.s2),
                Text(
                  'Heart rate · SpO2 · Temperature',
                  style: MecType.axisTick.copyWith(color: c.inkSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the connection could not be made.
///
/// The body scrolls inside the card rather than growing it: this sits in the
/// guide's fixed-height viewport, and a diagnostic list is exactly the content
/// whose length cannot be predicted.
class PairErrorCard extends StatelessWidget {
  const PairErrorCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecCard.status(
      MecRiskBand.high.color,
      padding: const EdgeInsets.all(MecSpace.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline, size: 18, color: MecRiskBand.high.color),
              const SizedBox(width: MecSpace.s12),
              // The word carries the state. The red is on the icon only, which
              // needs 3:1 rather than the 4.5:1 a label would.
              Expanded(
                child: Text(
                  'Connection failed',
                  style: MecType.label.copyWith(
                    color: c.inkPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                message,
                style: MecType.axisTick.copyWith(
                  color: c.inkSecondary,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
