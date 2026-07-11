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
class ScoutSampleGate {
  final SessionManager? Function() sessionResolver;
  final bool alwaysCaptureErrors;

  const ScoutSampleGate({
    required this.sessionResolver,
    required this.alwaysCaptureErrors,
  });

  bool _sessionSampled() => sessionResolver()?.isSampled ?? false;

  /// Whether a span with [name] should be recorded and exported.
  bool shouldSampleSpan(String name) {
    if (alwaysCaptureErrors && kErrorClassSpans.contains(name)) return true;
    return _sessionSampled();
  }

  /// Whether metric data points should be recorded.
  bool shouldSampleMetric() => _sessionSampled();

  /// Whether a log entry should be exported. [isError] marks
  /// error-severity entries, which bypass sampling when
  /// [alwaysCaptureErrors] is set.
  bool shouldSampleLog({required bool isError}) {
    if (alwaysCaptureErrors && isError) return true;
    return _sessionSampled();
  }
}
