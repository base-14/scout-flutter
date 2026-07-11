import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'scout_debug_logger.dart';
import 'session_manager.dart';

const Set<String> kErrorClassSpans = <String>{
  'error',
  'native_crash',
  'app_crash',
  'anr',
  'ui_hang',
};

class ScoutSessionSampler implements Sampler {
  final SessionManager? Function() _sessionResolver;
  final bool alwaysCaptureErrors;
  final ScoutDebugLogger? _logger;

  ScoutSessionSampler({
    required SessionManager? Function() sessionResolver,
    required this.alwaysCaptureErrors,
    ScoutDebugLogger? logger,
  }) : _sessionResolver = sessionResolver,
       _logger = logger;

  @override
  String get description => 'ScoutSessionSampler';

  @override
  SamplingResult shouldSample({
    required Context parentContext,
    required String traceId,
    required String name,
    required SpanKind spanKind,
    required Attributes? attributes,
    required List<SpanLink>? links,
  }) {
    if (alwaysCaptureErrors && kErrorClassSpans.contains(name)) {
      _logger?.sample(name: name, decision: 'recordAndSample (error bypass)');
      return const SamplingResult(
        decision: SamplingDecision.recordAndSample,
        source: SamplingDecisionSource.tracerConfig,
      );
    }

    // Fail closed: no session yet means "drop", never "leak". The
    // SessionManager is constructed before the tracer, so this only
    // guards pathological orderings.
    final session = _sessionResolver();
    final sampled = session?.isSampled ?? false;
    _logger?.sample(name: name, decision: sampled ? 'recordAndSample' : 'drop');
    return SamplingResult(
      decision:
          sampled ? SamplingDecision.recordAndSample : SamplingDecision.drop,
      source: SamplingDecisionSource.tracerConfig,
    );
  }
}
