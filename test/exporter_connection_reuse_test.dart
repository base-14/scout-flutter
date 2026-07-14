import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/fixed_http_log_exporter.dart';
import 'package:scout_flutter/src/fixed_http_metric_exporter.dart';
import 'package:scout_flutter/src/fixed_http_span_exporter.dart';

/// Each TCP connection from the client uses a distinct ephemeral port, so
/// the number of distinct remote ports seen by the server counts the
/// connections. Reused (keep-alive) connections show one port across many
/// requests; a new client per request shows one port per request.
void main() {
  late HttpServer server;
  late List<int> remotePorts;
  late int requests;

  setUp(() async {
    remotePorts = [];
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      remotePorts.add(request.connectionInfo?.remotePort ?? -1);
      await request.drain<void>();
      request.response.statusCode = 200;
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String endpoint() => 'http://127.0.0.1:${server.port}';

  Metric metric(String name) =>
      Metric(name: name, type: MetricType.gauge, points: const []);

  ScoutLogRecord record(String body) => ScoutLogRecord(
    severityNumber: 9,
    severityText: 'INFO',
    body: body,
    timestampNanos: BigInt.from(1000),
  );

  test('metric exporter reuses one connection across exports', () async {
    final exporter = FixedHttpMetricExporter(endpoint: endpoint());

    for (var i = 0; i < 3; i++) {
      expect(
        await exporter.export(MetricData(metrics: [metric('m$i')])),
        isTrue,
      );
    }

    expect(requests, 3);
    expect(
      remotePorts.toSet(),
      hasLength(1),
      reason: 'three exports must share one TCP connection',
    );
    await exporter.shutdown();
  });

  test('log exporter reuses one connection across exports', () async {
    final exporter = FixedHttpLogExporter(endpoint: endpoint());

    for (var i = 0; i < 3; i++) {
      expect(await exporter.export([record('log $i')]), isTrue);
    }

    expect(requests, 3);
    expect(
      remotePorts.toSet(),
      hasLength(1),
      reason: 'three exports must share one TCP connection',
    );
    await exporter.shutdown();
  });

  test('span exporter reuses one connection across exports', () async {
    await OTel.initialize(
      serviceName: 'reuse-test',
      endpoint: 'http://localhost:4318',
    );
    final tracer = OTel.tracer();

    final exporter = FixedHttpSpanExporter(endpoint: endpoint());

    for (var i = 0; i < 3; i++) {
      final span = tracer.startSpan('span-$i');
      span.end();
      await exporter.export([span]);
    }

    expect(requests, 3);
    expect(
      remotePorts.toSet(),
      hasLength(1),
      reason: 'three exports must share one TCP connection',
    );
    await exporter.shutdown();
  });
}
