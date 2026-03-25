import 'package:flutter/scheduler.dart';

/// Collects frame timing metrics from Flutter's rendering pipeline.
///
/// Subscribes to [SchedulerBinding.addTimingsCallback] to receive
/// [FrameTiming] data for every rendered frame. Reports:
/// - Build duration (widget tree construction)
/// - Raster duration (GPU rasterization)
/// - Frozen frames (total frame time > 700ms)
class FrameMetricsCollector {
  final void Function(Duration buildTime, Duration rasterTime) onFrameTiming;
  final void Function(Duration totalDuration)? onFrozenFrame;
  final Duration frozenFrameThreshold;

  bool _collecting = false;

  FrameMetricsCollector({
    required this.onFrameTiming,
    this.onFrozenFrame,
    this.frozenFrameThreshold = const Duration(milliseconds: 700),
  });

  bool get isCollecting => _collecting;

  void start() {
    if (_collecting) return;
    _collecting = true;
    SchedulerBinding.instance.addTimingsCallback(_handleTimings);
  }

  void stop() {
    if (!_collecting) return;
    _collecting = false;
    SchedulerBinding.instance.removeTimingsCallback(_handleTimings);
  }

  void _handleTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildDuration = timing.buildDuration;
      final rasterDuration = timing.rasterDuration;
      final totalDuration = timing.totalSpan;

      onFrameTiming(buildDuration, rasterDuration);

      if (onFrozenFrame != null && totalDuration >= frozenFrameThreshold) {
        onFrozenFrame!(totalDuration);
      }
    }
  }
}
