import 'package:flutter/widgets.dart';

/// Detects when the Dart event loop is blocked for longer than [threshold].
///
/// Uses a polling loop with a 13ms delay (just under one 60fps frame at
/// ~16.67ms). Each iteration measures the actual elapsed time using a monotonic
/// [Stopwatch]; if it exceeds [threshold], the [onLongTask] callback fires
/// with the measured duration.
///
/// Implements [WidgetsBindingObserver] to automatically pause detection when the
/// app is backgrounded and resume when it returns to the foreground.
class LongTaskDetector with WidgetsBindingObserver {
  /// Duration above which a blocked event loop is considered a long task.
  final Duration threshold;

  /// Called whenever a long task is detected. The argument is the actual
  /// duration the event loop was blocked.
  final void Function(Duration duration) onLongTask;

  bool _detecting = false;
  Future<void>? _detectorFuture;

  LongTaskDetector({
    this.threshold = const Duration(milliseconds: 100),
    required this.onLongTask,
  });

  /// Whether the detector is currently running.
  bool get isRunning => _detecting;

  /// Begins long-task detection and registers as a lifecycle observer.
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _startDetection();
  }

  /// Stops long-task detection and unregisters the lifecycle observer.
  Future<void> stop() async {
    WidgetsBinding.instance.removeObserver(this);
    await _stopDetection();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _startDetection();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _stopDetection();
        break;
    }
  }

  void _startDetection() {
    if (!_detecting) {
      _detecting = true;
      _detectorFuture = _detectionLoop();
    }
  }

  Future<void> _stopDetection() async {
    if (_detecting) {
      _detecting = false;
      await _detectorFuture;
      _detectorFuture = null;
    }
  }

  Future<void> _detectionLoop() async {
    final thresholdMs = threshold.inMilliseconds;
    final stopwatch = Stopwatch()..start();

    while (_detecting) {
      await Future<void>.delayed(const Duration(milliseconds: 13));
      final elapsed = stopwatch.elapsedMilliseconds;
      stopwatch.reset();

      if (_detecting && elapsed > thresholdMs) {
        onLongTask(Duration(milliseconds: elapsed));
      }
    }
  }
}
