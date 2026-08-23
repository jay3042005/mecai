/// Heart rate detail screen.
///
/// A named entry point over [VitalDetailScreen], which carries the shared layout.
/// The product separates these three surfaces; the *implementation* stays single
/// so a chart fix lands in one place rather than three — the same argument
/// `packages/tokens` makes about colour values.
library;

import 'package:flutter/material.dart';

import '../data/monitor_controller.dart';
import '../models/vital_spec.dart';
import 'vital_detail_screen.dart';

class HeartRateScreen extends StatelessWidget {
  const HeartRateScreen({super.key, required this.controller});

  final MonitorController controller;

  @override
  Widget build(BuildContext context) => VitalDetailScreen(
        spec: VitalSpec.heartRate,
        controller: controller,
      );
}
