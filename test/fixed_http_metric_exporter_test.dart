import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/collector/metrics/v1/metrics_service.pb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/fixed_http_metric_exporter.dart';

Metric _metric(String name) =>
    Metric(name: name, type: MetricType.gauge, points: const []);

void main() {
  group('FixedHttpMetricExporter lifecycle metric filter', () {
    late HttpServer server;
    late List<ExportMetricsServiceRequest> received;

    setUp(() async {
      received = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (acc, chunk) => acc..addAll(chunk),
        );
        received.add(ExportMetricsServiceRequest.fromBuffer(bytes));
        request.response.statusCode = 200;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'drops flutter.lifecycle.state_change but exports other metrics',
      () async {
        final exporter = FixedHttpMetricExporter(
          endpoint: 'http://127.0.0.1:${server.port}',
        );

        final ok = await exporter.export(
          MetricData(
            metrics: [
              _metric('flutter.lifecycle.state_change'),
              _metric('flutter.memory.usage'),
            ],
          ),
        );

        expect(ok, isTrue);
        expect(received, hasLength(1));
        final names =
            received.single.resourceMetrics
                .expand((rm) => rm.scopeMetrics)
                .expand((sm) => sm.metrics)
                .map((m) => m.name)
                .toList();
        expect(names, ['flutter.memory.usage']);
      },
    );

    test(
      'drops flutter.frame.duration when frame metrics are disabled',
      () async {
        final exporter = FixedHttpMetricExporter(
          endpoint: 'http://127.0.0.1:${server.port}',
          dropMetricNames: const {'flutter.frame.duration'},
        );

        final ok = await exporter.export(
          MetricData(
            metrics: [
              _metric('flutter.frame.duration'),
              _metric('flutter.cpu.usage'),
            ],
          ),
        );

        expect(ok, isTrue);
        final names =
            received.single.resourceMetrics
                .expand((rm) => rm.scopeMetrics)
                .expand((sm) => sm.metrics)
                .map((m) => m.name)
                .toList();
        expect(names, ['flutter.cpu.usage']);
      },
    );

    test('keeps flutter.frame.duration when not asked to drop it', () async {
      final exporter = FixedHttpMetricExporter(
        endpoint: 'http://127.0.0.1:${server.port}',
      );

      final ok = await exporter.export(
        MetricData(metrics: [_metric('flutter.frame.duration')]),
      );

      expect(ok, isTrue);
      final names =
          received.single.resourceMetrics
              .expand((rm) => rm.scopeMetrics)
              .expand((sm) => sm.metrics)
              .map((m) => m.name)
              .toList();
      expect(names, ['flutter.frame.duration']);
    });

    test(
      'skips the HTTP request entirely when all metrics are filtered',
      () async {
        final exporter = FixedHttpMetricExporter(
          endpoint: 'http://127.0.0.1:${server.port}',
        );

        final ok = await exporter.export(
          MetricData(metrics: [_metric('flutter.lifecycle.state_change')]),
        );

        expect(ok, isTrue);
        expect(received, isEmpty);
      },
    );
  });
}
