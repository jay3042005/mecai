/// Staggered entrance — MD3's list and grid arrival.
///
/// Items fade and rise into place one after another, `MecMotion.stagger` apart,
/// on `MecEasing.decelerate` (MD3 Emphasized Decelerate is specifically the curve
/// for elements entering the screen).
///
/// This is motion that means *change* — content arriving — which is the test
/// docs/design.md §2 principle 3 sets. Under reduced motion the child is returned
/// untouched, arriving instantly rather than sliding.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';

class MecStagger extends StatefulWidget {
  const MecStagger({
    super.key,
    required this.index,
    required this.child,
    this.rise = 12,
  });

  /// Position in the run. Delay is `index × MecMotion.stagger`.
  final int index;

  final Widget child;

  /// Distance travelled, in logical pixels. Small on purpose.
  final double rise;

  @override
  State<MecStagger> createState() => _MecStaggerState();
}

class _MecStaggerState extends State<MecStagger> {
  bool _in = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(MecMotion.stagger * widget.index, () {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (context.reduceMotion) return widget.child;

    return AnimatedSlide(
      offset: _in ? Offset.zero : Offset(0, widget.rise / 100),
      duration: MecMotion.fast,
      curve: MecEasing.decelerate,
      child: AnimatedOpacity(
        opacity: _in ? 1 : 0,
        duration: MecMotion.fast,
        curve: MecEasing.decelerate,
        child: widget.child,
      ),
    );
  }
}
