import 'package:scout_flutter/scout_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScoutFlutterConfig', () {
    test('creates with required fields only', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.serviceName, 'test-app');
      expect(config.endpoint, 'https://otel.example.com');
      expect(config.serviceVersion, '1.0.0');
      expect(config.enableAutoTapTracking, true);
      expect(config.enableErrorTracking, true);
      expect(config.enableLifecycleTracking, true);
      expect(config.customGestureDetector, isNull);
      expect(config.enableLongTaskDetection, true);
      expect(config.longTaskThresholdMs, 100);
      expect(config.enableAnrDetection, true);
      expect(config.anrThresholdMs, 5000);
      expect(config.sessionSampleRate, 1.0);
      expect(config.alwaysCaptureErrors, true);
      expect(config.debugLogging, false);
    });

    test('creates with all optional fields', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        serviceVersion: '2.0.0',
        environment: 'staging',
        resourceAttributes: {'team': 'mobile'},
        enableAutoTapTracking: false,
        enableErrorTracking: false,
        enableLifecycleTracking: false,
        enableLongTaskDetection: false,
        longTaskThresholdMs: 200,
        enableAnrDetection: false,
        anrThresholdMs: 10000,
      );

      expect(config.serviceVersion, '2.0.0');
      expect(config.environment, 'staging');
      expect(config.resourceAttributes, {'team': 'mobile'});
      expect(config.enableAutoTapTracking, false);
      expect(config.enableLongTaskDetection, false);
      expect(config.longTaskThresholdMs, 200);
      expect(config.enableAnrDetection, false);
      expect(config.anrThresholdMs, 10000);
    });

    test('clamps longTaskThresholdMs to minimum of 20', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        longTaskThresholdMs: 5,
      );

      expect(config.longTaskThresholdMs, 20);
    });

    test('allows longTaskThresholdMs at exactly 20', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        longTaskThresholdMs: 20,
      );

      expect(config.longTaskThresholdMs, 20);
    });

    test('allows longTaskThresholdMs above 20', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        longTaskThresholdMs: 50,
      );

      expect(config.longTaskThresholdMs, 50);
    });

    test('clamps longTaskThresholdMs when zero is passed', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        longTaskThresholdMs: 0,
      );

      expect(config.longTaskThresholdMs, 20);
    });

    test('clamps longTaskThresholdMs when negative value is passed', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        longTaskThresholdMs: -10,
      );

      expect(config.longTaskThresholdMs, 20);
    });

    test('clamps anrThresholdMs to minimum of 1000', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        anrThresholdMs: 500,
      );

      expect(config.anrThresholdMs, 1000);
    });

    test('allows anrThresholdMs at exactly 1000', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        anrThresholdMs: 1000,
      );

      expect(config.anrThresholdMs, 1000);
    });

    test('clamps anrThresholdMs when zero is passed', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        anrThresholdMs: 0,
      );

      expect(config.anrThresholdMs, 1000);
    });
  });
}
