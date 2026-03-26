import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/fixed_http_log_exporter.dart';

void main() {
  group('FixedHttpLogExporter', () {
    test('can be constructed with endpoint', () {
      final exporter = FixedHttpLogExporter(endpoint: 'http://localhost:4318');
      expect(exporter, isNotNull);
    });

    test('export returns true for empty log list', () async {
      final exporter = FixedHttpLogExporter(endpoint: 'http://localhost:4318');
      final result = await exporter.export([]);
      expect(result, isTrue);
    });

    test('export returns false after shutdown', () async {
      final exporter = FixedHttpLogExporter(endpoint: 'http://localhost:4318');
      await exporter.shutdown();
      final result = await exporter.export([
        ScoutLogRecord(
          severityNumber: 9,
          severityText: 'INFO',
          body: 'test message',
          timestampNanos: BigInt.from(DateTime.now().microsecondsSinceEpoch) *
              BigInt.from(1000),
        ),
      ]);
      expect(result, isFalse);
    });

    test('shutdown is idempotent', () async {
      final exporter = FixedHttpLogExporter(endpoint: 'http://localhost:4318');
      expect(await exporter.shutdown(), isTrue);
      expect(await exporter.shutdown(), isTrue);
    });

    test('forceFlush returns true', () async {
      final exporter = FixedHttpLogExporter(endpoint: 'http://localhost:4318');
      expect(await exporter.forceFlush(), isTrue);
    });
  });
}
