import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/fixed_http_span_exporter.dart';

void main() {
  group('FixedHttpSpanExporter', () {
    late HttpServer server;
    late int requests;
    late int statusCode;

    setUpAll(() async {
      await OTel.initialize(
        serviceName: 'span-exporter-test',
        endpoint: 'http://localhost:4318',
      );
    });

    setUp(() async {
      requests = 0;
      statusCode = 500;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.statusCode = statusCode;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'is at-most-once by default: a failed batch is never retried',
      () async {
        final exporter = FixedHttpSpanExporter(
          endpoint: 'http://127.0.0.1:${server.port}',
        );
        final span = OTel.tracer().startSpan('doomed')..end();

        await exporter.export([span]);

        expect(
          requests,
          1,
          reason: 'maxRetries defaults to 0 — one attempt, no duplicates',
        );
        await exporter.shutdown();
      },
    );

    test('sends auth headers with the export', () async {
      statusCode = 200;
      final received = <String, String>{};
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        received['authorization'] =
            request.headers.value('authorization') ?? '';
        received['content-type'] = request.headers.value('content-type') ?? '';
        await request.drain<void>();
        request.response.statusCode = 200;
        await request.response.close();
      });

      final exporter = FixedHttpSpanExporter(
        endpoint: 'http://127.0.0.1:${server.port}',
        headers: {'Authorization': 'Bearer x'},
      );
      final span = OTel.tracer().startSpan('authed')..end();
      await exporter.export([span]);

      expect(received['authorization'], 'Bearer x');
      expect(received['content-type'], 'application/x-protobuf');
      await exporter.shutdown();
    });
  });
}
