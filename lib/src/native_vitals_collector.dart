import 'dart:async';

import 'scout_platform_channel.dart';

/// Periodically polls native platform for memory and CPU metrics.
///
/// Either callback may be null, in which case the corresponding
/// platform-channel poll is skipped entirely (no wasted native calls).
class NativeVitalsCollector {
  final Duration interval;
  final void Function(int usedBytes, int maxBytes)? onMemory;
  final void Function(double cpuPercent)? onCpu;

  Timer? _timer;
  int? _lastCpuTicks;
  DateTime? _lastCpuTime;

  NativeVitalsCollector({
    this.interval = const Duration(milliseconds: 500),
    required this.onMemory,
    required this.onCpu,
  });

  bool get isCollecting => _timer != null;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _collect());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastCpuTicks = null;
    _lastCpuTime = null;
  }

  Future<void> _collect() async {
    final onMemory = this.onMemory;
    if (onMemory != null) {
      try {
        final memory = await ScoutPlatformChannel.getMemoryUsage();
        final used = memory['used'] as int? ?? -1;
        final max = memory['max'] as int? ?? -1;
        if (used > 0) {
          onMemory(used, max);
        }
      } catch (_) {}
    }

    final onCpu = this.onCpu;
    if (onCpu != null) {
      try {
        final cpu = await ScoutPlatformChannel.getCpuUsage();
        // iOS returns cpu_percent directly
        if (cpu.containsKey('cpu_percent')) {
          final percent = (cpu['cpu_percent'] as num).toDouble();
          onCpu(percent);
        }
        // Android returns ticks — compute delta
        else if (cpu.containsKey('ticks')) {
          final ticks = cpu['ticks'] as int;
          if (ticks >= 0 && _lastCpuTicks != null && _lastCpuTime != null) {
            final elapsed =
                DateTime.now().difference(_lastCpuTime!).inMilliseconds;
            if (elapsed > 0) {
              final tickDelta = ticks - _lastCpuTicks!;
              final cpuMs = tickDelta * 10;
              final percent = (cpuMs / elapsed) * 100.0;
              onCpu(percent.clamp(0, 100));
            }
          }
          _lastCpuTicks = ticks;
          _lastCpuTime = DateTime.now();
        }
      } catch (_) {}
    }
  }
}
