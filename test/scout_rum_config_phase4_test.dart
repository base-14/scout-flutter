import 'package:scout_flutter/scout_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScoutFlutterConfig metric intervals', () {
    test('metricExportIntervalSeconds defaults to null (unified interval)', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.metricExportIntervalSeconds, isNull);
    });

    test('honors explicit metricExportIntervalSeconds', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        metricExportIntervalSeconds: 30,
      );

      expect(config.metricExportIntervalSeconds, 30);
    });

    test('clamps metricExportIntervalSeconds to minimum of 1', () {
      final zero = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        metricExportIntervalSeconds: 0,
      );
      final negative = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        metricExportIntervalSeconds: -10,
      );

      expect(zero.metricExportIntervalSeconds, 1);
      expect(negative.metricExportIntervalSeconds, 1);
    });

    test('vitalsCollectionIntervalSeconds defaults to 60', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.vitalsCollectionIntervalSeconds, 60);
    });

    test('honors explicit vitalsCollectionIntervalSeconds', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        vitalsCollectionIntervalSeconds: 5,
      );

      expect(config.vitalsCollectionIntervalSeconds, 5);
    });

    test('clamps vitalsCollectionIntervalSeconds to minimum of 1', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        vitalsCollectionIntervalSeconds: 0,
      );

      expect(config.vitalsCollectionIntervalSeconds, 1);
    });
  });

  group('ScoutFlutterConfig per-metric switches', () {
    test('enableFrameMetrics defaults to false', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.enableFrameMetrics, false);
    });

    test('enableMemoryMetrics and enableCpuMetrics default to false', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.enableMemoryMetrics, false);
      expect(config.enableCpuMetrics, false);
    });

    test('honors explicit per-metric switches', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        enableFrameMetrics: true,
        enableMemoryMetrics: false,
        enableCpuMetrics: false,
      );

      expect(config.enableFrameMetrics, true);
      expect(config.enableMemoryMetrics, false);
      expect(config.enableCpuMetrics, false);
    });
  });
}
