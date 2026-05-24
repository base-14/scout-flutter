import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

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

  ScoutSessionSampler({
    required SessionManager? Function() sessionResolver,
    required this.alwaysCaptureErrors,
  }) : _sessionResolver = sessionResolver;

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
      return const SamplingResult(
        decision: SamplingDecision.recordAndSample,
        source: SamplingDecisionSource.tracerConfig,
      );
    }

    final session = _sessionResolver();
    final sampled = session?.isSampled ?? true;
    return SamplingResult(
      decision:
          sampled ? SamplingDecision.recordAndSample : SamplingDecision.drop,
      source: SamplingDecisionSource.tracerConfig,
    );
  }
}
