import 'package:scout_flutter/scout_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

ScoutFlutterConfig _config({
  int? exportIntervalSeconds,
  int? maxExportBatchSize,
  int? maxQueueSize,
  int? maxRetries,
  int? metricExportIntervalSeconds,
}) => ScoutFlutterConfig(
  serviceName: 'test-app',
  endpoint: 'https://otel.example.com',
  exportIntervalSeconds: exportIntervalSeconds ?? 30,
  maxExportBatchSize: maxExportBatchSize ?? 512,
  maxQueueSize: maxQueueSize ?? 2048,
  maxRetries: maxRetries ?? 0,
  metricExportIntervalSeconds: metricExportIntervalSeconds,
);

void main() {
  group('minimal-telemetry defaults', () {
    test('vitals gauges default to off', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.enableMemoryMetrics, false);
      expect(config.enableCpuMetrics, false);
      expect(config.enableFrameMetrics, false);
    });

    test('offline buffering defaults to fully disabled', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.offlineBufferEnabled, false);
      expect(config.offlineMaxTraceItems, 0);
      expect(config.offlineMaxMetricItems, 0);
      expect(config.offlineMaxLogItems, 0);
    });
  });

  group('unified export config', () {
    test('defaults: interval 30s, batch 512, queue 2048, retries 0', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.exportIntervalSeconds, 30);
      expect(config.maxExportBatchSize, 512);
      expect(config.maxQueueSize, 2048);
      expect(config.maxRetries, 0);
    });

    test('honors explicit values', () {
      final config = _config(
        exportIntervalSeconds: 10,
        maxExportBatchSize: 100,
        maxQueueSize: 500,
        maxRetries: 2,
      );

      expect(config.exportIntervalSeconds, 10);
      expect(config.maxExportBatchSize, 100);
      expect(config.maxQueueSize, 500);
      expect(config.maxRetries, 2);
    });

    test('clamps to sane minimums', () {
      final config = _config(
        exportIntervalSeconds: 0,
        maxExportBatchSize: 0,
        maxQueueSize: 0,
        maxRetries: -1,
      );

      expect(config.exportIntervalSeconds, 1);
      expect(config.maxExportBatchSize, 1);
      expect(config.maxQueueSize, 1);
      expect(config.maxRetries, 0);
    });

    test('metricExportIntervalSeconds defaults to null (use unified)', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.metricExportIntervalSeconds, isNull);
      expect(config.effectiveMetricExportIntervalSeconds, 30);
    });

    test('metricExportIntervalSeconds still works as a metrics override', () {
      final config = _config(metricExportIntervalSeconds: 60);

      expect(config.metricExportIntervalSeconds, 60);
      expect(config.effectiveMetricExportIntervalSeconds, 60);
    });
  });
}
