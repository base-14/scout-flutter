import 'scout_session_sampler.dart' show kErrorClassSpans;
import 'session_manager.dart';

/// The single source of truth for whether telemetry leaves the device.
///
/// Every emit path — spans, metrics, and logs — asks this gate, so the
/// per-session sampling decision applies uniformly to all three signals.
///
/// Fails closed: when no session exists yet (or the resolver returns
/// null), non-error telemetry is dropped rather than leaked. Error-class
/// spans and error-level logs bypass the gate when [alwaysCaptureErrors]
/// is set, even without a session, so crashes during initialization are
/// never lost.
///
/// While RUM is disabled ([enabledResolver] returns false) everything is
/// dropped, errors included: the kill switch overrides
/// [alwaysCaptureErrors].
class ScoutSampleGate {
  final SessionManager? Function() sessionResolver;
  final bool alwaysCaptureErrors;
  final bool Function() enabledResolver;

  const ScoutSampleGate({
    required this.sessionResolver,
    required this.alwaysCaptureErrors,
    this.enabledResolver = _alwaysEnabled,
  });

  static bool _alwaysEnabled() => true;

  bool _sessionSampled() => sessionResolver()?.isSampled ?? false;

  /// Spans follow `sampled`, but logs and metrics also flow for a user-"no"
  /// session. Only the fallback roll drops them.
  bool _logsAndMetricsAllowed() =>
      sessionResolver()?.allowsLogsAndMetrics ?? false;

  /// Whether a span with [name] should be recorded and exported.
  bool shouldSampleSpan(String name) {
    if (!enabledResolver()) return false;
    if (alwaysCaptureErrors && kErrorClassSpans.contains(name)) return true;
    return _sessionSampled();
  }

  /// Whether metric data points should be recorded.
  bool shouldSampleMetric() => enabledResolver() && _logsAndMetricsAllowed();

  /// Whether a log entry should be exported. [isError] marks
  /// error-severity entries, which bypass sampling when
  /// [alwaysCaptureErrors] is set.
  bool shouldSampleLog({required bool isError}) {
    if (!enabledResolver()) return false;
    if (alwaysCaptureErrors && isError) return true;
    return _logsAndMetricsAllowed();
  }
}
