import 'package:flutter/widgets.dart';
import 'scout_platform_channel.dart';

/// Outcome of a cold-start measurement.
class ColdStartResult {
  const ColdStartResult({required this.durationMs, required this.anchor});

  final int durationMs;

  /// `process_start` when the OS process start time anchored the
  /// measurement, `sdk_init` when it fell back to the stopwatch started
  /// in `ScoutFlutter.initialize()` (the 0.2.x behaviour).
  final String anchor;

  double get durationSeconds => durationMs / 1000.0;
}

/// Cold start = OS process start -> first rendered frame.
///
/// Two independent events must both happen before the value can be
/// emitted: the first post-frame callback (the end anchor, armed as
/// early as `initialize()` so it lands on the app's real first frame),
/// and the SDK becoming ready to export (session + tracer wired, which
/// happens after an async bootstrap). Whichever comes last triggers the
/// single emission.
///
/// The process start time comes from the platform (Android
/// `Process.getStartElapsedRealtime`, iOS `kp_proc.p_starttime`). When
/// it is unavailable — web/desktop, Android < 24, iOS prewarmed launch,
/// channel failure — or implausible, the tracker falls back to the
/// SDK-init stopwatch so nothing regresses.
class ColdStartTracker {
  ColdStartTracker({
    required this.onColdStart,
    Future<int?> Function()? processStartMs,
    int Function()? nowEpochMs,
    this.maxPlausibleMs = defaultMaxPlausibleMs,
  }) : _processStartMs =
           processStartMs ?? ScoutPlatformChannel.getProcessStartTimeMillis,
       _nowEpochMs =
           nowEpochMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _stopwatch = Stopwatch()..start();

  /// Anything longer is not a user-perceived launch — the OS pre-started
  /// the process for a push/job, an iOS prewarm slipped past the env-var
  /// check, or the wall clock stepped — and falls back to the stopwatch.
  static const int defaultMaxPlausibleMs = 60000;

  final void Function(ColdStartResult result) onColdStart;
  final Future<int?> Function() _processStartMs;
  final int Function() _nowEpochMs;
  final int maxPlausibleMs;
  final Stopwatch _stopwatch;

  bool _armed = false;
  bool _ready = false;
  bool _emitted = false;
  int? _nativeStartMs;
  int? _firstFrameAtMs;
  Duration? _firstFrameElapsed;

  bool get isRecorded => _emitted;

  /// Epoch ms of the first frame, once rendered.
  int? get firstFrameAtMs => _firstFrameAtMs;

  /// Register the end anchor. Call synchronously in `initialize()` right
  /// after `ensureInitialized()` — i.e. before `runApp()` — so the
  /// callback fires after the app's very first frame. Idempotent.
  void armFirstFrame() {
    if (_armed) return;
    _armed = true;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => markFirstFrame());
    } catch (_) {}
  }

  /// Record "first frame rendered now". Production code reaches it via
  /// the post-frame callback; tests call it directly.
  @visibleForTesting
  void markFirstFrame() {
    if (_firstFrameAtMs != null) return;
    _firstFrameAtMs = _nowEpochMs();
    _firstFrameElapsed = _stopwatch.elapsed;
    _tryEmit();
  }

  /// Fetch the native process start and mark the exporter as ready.
  Future<void> ready() async {
    if (_ready) return;
    try {
      _nativeStartMs = await _processStartMs();
    } catch (_) {
      _nativeStartMs = null;
    }
    _ready = true;
    _tryEmit();
  }

  void _tryEmit() {
    if (_emitted || !_ready) return;
    final at = _firstFrameAtMs;
    final elapsed = _firstFrameElapsed;
    if (at == null || elapsed == null) return;
    _emitted = true;
    _stopwatch.stop();
    onColdStart(
      resolve(
        nativeStartMs: _nativeStartMs,
        firstFrameAtMs: at,
        fallbackElapsed: elapsed,
        maxPlausibleMs: maxPlausibleMs,
      ),
    );
  }

  /// Pick the process-start anchor when present and plausible, else the
  /// SDK-init stopwatch.
  @visibleForTesting
  static ColdStartResult resolve({
    required int? nativeStartMs,
    required int firstFrameAtMs,
    required Duration fallbackElapsed,
    int maxPlausibleMs = defaultMaxPlausibleMs,
  }) {
    if (nativeStartMs != null && nativeStartMs > 0) {
      final d = firstFrameAtMs - nativeStartMs;
      if (d >= 0 && d <= maxPlausibleMs) {
        return ColdStartResult(durationMs: d, anchor: 'process_start');
      }
    }
    return ColdStartResult(
      durationMs: fallbackElapsed.inMilliseconds,
      anchor: 'sdk_init',
    );
  }
}
