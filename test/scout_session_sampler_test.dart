import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_session_sampler.dart';
import 'package:scout_flutter/src/session_manager.dart';

late Context _rootContext;

SamplingResult _shouldSample(ScoutSessionSampler sampler, String name) {
  return sampler.shouldSample(
    parentContext: _rootContext,
    traceId: '00000000000000000000000000000001',
    name: name,
    spanKind: SpanKind.internal,
    attributes: null,
    links: null,
  );
}

void main() {
  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'sampler-test',
      endpoint: 'http://localhost:4318',
    );
    _rootContext = Context.root;
  });

  group('ScoutSessionSampler', () {
    test('records when session is sampled', () {
      final sm = SessionManager(sampleRate: 100, timeoutMinutes: 30);
      final sampler = ScoutSessionSampler(
        sessionResolver: () => sm,
        alwaysCaptureErrors: true,
      );
      expect(
        _shouldSample(sampler, 'user_interaction').decision,
        SamplingDecision.recordAndSample,
      );
    });

    test('drops non-error spans when session not sampled', () {
      final sm = SessionManager(sampleRate: 0, timeoutMinutes: 30);
      final sampler = ScoutSessionSampler(
        sessionResolver: () => sm,
        alwaysCaptureErrors: true,
      );
      expect(
        _shouldSample(sampler, 'user_interaction').decision,
        SamplingDecision.drop,
      );
      expect(
        _shouldSample(sampler, 'http.request').decision,
        SamplingDecision.drop,
      );
      expect(
        _shouldSample(sampler, 'screen_view').decision,
        SamplingDecision.drop,
      );
    });

    test('error-class spans bypass sampling when alwaysCaptureErrors=true', () {
      final sm = SessionManager(sampleRate: 0, timeoutMinutes: 30);
      final sampler = ScoutSessionSampler(
        sessionResolver: () => sm,
        alwaysCaptureErrors: true,
      );
      for (final name in const [
        'error',
        'native_crash',
        'app_crash',
        'anr',
        'ui_hang',
      ]) {
        expect(
          _shouldSample(sampler, name).decision,
          SamplingDecision.recordAndSample,
          reason: 'span $name should bypass sampling',
        );
      }
    });

    test(
      'error-class spans respect sampling when alwaysCaptureErrors=false',
      () {
        final sm = SessionManager(sampleRate: 0, timeoutMinutes: 30);
        final sampler = ScoutSessionSampler(
          sessionResolver: () => sm,
          alwaysCaptureErrors: false,
        );
        expect(_shouldSample(sampler, 'error').decision, SamplingDecision.drop);
        expect(
          _shouldSample(sampler, 'native_crash').decision,
          SamplingDecision.drop,
        );
      },
    );

    test('fails closed (drops) when session is null', () {
      final sampler = ScoutSessionSampler(
        sessionResolver: () => null,
        alwaysCaptureErrors: true,
      );
      expect(
        _shouldSample(sampler, 'user_interaction').decision,
        SamplingDecision.drop,
      );
      // Errors still bypass even without a session.
      expect(
        _shouldSample(sampler, 'error').decision,
        SamplingDecision.recordAndSample,
      );
    });
  });
}
