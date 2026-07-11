import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_sample_gate.dart';
import 'package:scout_flutter/src/session_manager.dart';

void main() {
  SessionManager sampled() =>
      SessionManager(sampleRate: 100, timeoutMinutes: 30);
  SessionManager unsampled() =>
      SessionManager(sampleRate: 0, timeoutMinutes: 30);

  group('ScoutSampleGate spans', () {
    test('allows spans when session is sampled', () {
      final sm = sampled();
      final gate = ScoutSampleGate(
        sessionResolver: () => sm,
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleSpan('user_interaction'), isTrue);
      expect(gate.shouldSampleSpan('long_task'), isTrue);
    });

    test('drops spans when session is not sampled — including long_task', () {
      final sm = unsampled();
      final gate = ScoutSampleGate(
        sessionResolver: () => sm,
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleSpan('user_interaction'), isFalse);
      expect(gate.shouldSampleSpan('long_task'), isFalse);
      expect(gate.shouldSampleSpan('http.request'), isFalse);
      expect(gate.shouldSampleSpan('screen_view'), isFalse);
    });

    test('error-class spans bypass sampling when alwaysCaptureErrors', () {
      final sm = unsampled();
      final gate = ScoutSampleGate(
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
        expect(gate.shouldSampleSpan(name), isTrue, reason: name);
      }
    });

    test('error-class spans follow session when alwaysCaptureErrors=false', () {
      final sm = unsampled();
      final gate = ScoutSampleGate(
        sessionResolver: () => sm,
        alwaysCaptureErrors: false,
      );
      expect(gate.shouldSampleSpan('error'), isFalse);
      expect(gate.shouldSampleSpan('native_crash'), isFalse);
    });

    test('fails closed when session does not exist yet', () {
      final gate = ScoutSampleGate(
        sessionResolver: () => null,
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleSpan('long_task'), isFalse);
      expect(gate.shouldSampleSpan('user_interaction'), isFalse);
    });

    test('errors are still captured even without a session', () {
      final gate = ScoutSampleGate(
        sessionResolver: () => null,
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleSpan('error'), isTrue);
      expect(gate.shouldSampleSpan('native_crash'), isTrue);
    });
  });

  group('ScoutSampleGate metrics', () {
    test('metrics follow the session decision', () {
      final on = ScoutSampleGate(
        sessionResolver: () => sampled(),
        alwaysCaptureErrors: true,
      );
      final off = ScoutSampleGate(
        sessionResolver: () => unsampled(),
        alwaysCaptureErrors: true,
      );
      expect(on.shouldSampleMetric(), isTrue);
      expect(off.shouldSampleMetric(), isFalse);
    });

    test('metrics fail closed without a session', () {
      final gate = ScoutSampleGate(
        sessionResolver: () => null,
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleMetric(), isFalse);
    });
  });

  group('ScoutSampleGate logs', () {
    test('logs follow the session decision', () {
      final on = ScoutSampleGate(
        sessionResolver: () => sampled(),
        alwaysCaptureErrors: true,
      );
      final off = ScoutSampleGate(
        sessionResolver: () => unsampled(),
        alwaysCaptureErrors: true,
      );
      expect(on.shouldSampleLog(isError: false), isTrue);
      expect(off.shouldSampleLog(isError: false), isFalse);
    });

    test('error logs bypass sampling when alwaysCaptureErrors', () {
      final gate = ScoutSampleGate(
        sessionResolver: () => unsampled(),
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleLog(isError: true), isTrue);
    });

    test('error logs follow session when alwaysCaptureErrors=false', () {
      final gate = ScoutSampleGate(
        sessionResolver: () => unsampled(),
        alwaysCaptureErrors: false,
      );
      expect(gate.shouldSampleLog(isError: true), isFalse);
    });

    test('logs fail closed without a session', () {
      final gate = ScoutSampleGate(
        sessionResolver: () => null,
        alwaysCaptureErrors: true,
      );
      expect(gate.shouldSampleLog(isError: false), isFalse);
    });
  });
}
