import 'package:flutter/foundation.dart';

class ScoutDebugLogger {
  final bool enabled;
  static const String _prefix = '[scout]';
  static const int _maxMessageChars = 80;

  const ScoutDebugLogger({required this.enabled});

  void init({
    required String serviceName,
    required String endpoint,
    required String version,
    required double sampleRate,
    required bool alwaysCaptureErrors,
  }) {
    if (!enabled) return;
    debugPrint(
      '$_prefix init ok (service=$serviceName endpoint=$endpoint '
      'v=$version sampleRate=$sampleRate '
      'alwaysCaptureErrors=$alwaysCaptureErrors)',
    );
  }

  void session({required String sessionId, required bool sampled}) {
    if (!enabled) return;
    debugPrint('$_prefix session $sessionId sampled=$sampled');
  }

  void sample({required String name, required String decision}) {
    if (!enabled) return;
    debugPrint('$_prefix span $name → $decision');
  }

  void exportBatch({
    required int spans,
    required int durationMs,
    required bool ok,
    String? error,
  }) {
    if (!enabled) return;
    final status = ok ? 'ok' : 'FAILED${error != null ? " ($error)" : ""}';
    debugPrint('$_prefix export batch: $spans spans (${durationMs}ms) $status');
  }

  void log({required String level, required String message}) {
    if (!enabled) return;
    final truncated =
        message.length > _maxMessageChars
            ? '${message.substring(0, _maxMessageChars - 3)}...'
            : message;
    debugPrint('$_prefix log [$level] $truncated');
  }

  void error(String message) {
    if (!enabled) return;
    debugPrint('$_prefix error: $message');
  }
}
