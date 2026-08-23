/// Press feedback — the Material You "tactile" trait.
///
/// MD3 asks every interactive surface to shrink slightly while held. It is the
/// smallest of the micro-interactions and the one most responsible for an app
/// feeling responsive rather than static.
///
/// This is deliberately **visual only**: it listens to raw pointer events rather
/// than claiming the gesture, so an inner `InkWell`, `FilledButton` or
/// `GestureDetector` still receives the tap and still draws its own state layer.
/// Wrap, don't replace:
///
/// ```dart
/// MecPress(child: FilledButton(onPressed: ..., child: ...))
/// ```
///
/// Scale is suppressed under reduced motion, where a shrinking target is exactly
/// the kind of movement docs/design.md §3.6 asks us to drop.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';

class MecPress extends StatefulWidget {
  const MecPress({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = 0.96,
  });

  final Widget child;

  /// Set false for a disabled control, so it stays inert under a press.
  final bool enabled;

  /// Held scale. MD3's own value is 0.95; 0.96 reads better on large cards.
  final double scale;

  @override
  State<MecPress> createState() => _MecPressState();
}

class _MecPressState extends State<MecPress> {
  bool _held = false;

  void _set(bool v) {
    if (_held == v || !widget.enabled) return;
    setState(() => _held = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || context.reduceMotion) return widget.child;

    return Listener(
      // Listener observes without entering the gesture arena, so the child's own
      // tap handling is untouched.
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _held ? widget.scale : 1.0,
        duration: MecMotion.instant,
        curve: MecEasing.standard,
        child: widget.child,
      ),
    );
  }
}
