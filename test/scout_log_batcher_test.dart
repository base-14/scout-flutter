import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/fixed_http_log_exporter.dart';
import 'package:scout_flutter/src/scout_log_batcher.dart';

ScoutLogRecord _record(String body) => ScoutLogRecord(
  severityNumber: 9,
  severityText: 'INFO',
  body: body,
  timestampNanos: BigInt.from(1000),
);

void main() {
  group('ScoutLogBatcher', () {
    test('buffers logs and exports one batch when the interval elapses', () {
      fakeAsync((async) {
        final exported = <List<ScoutLogRecord>>[];
        final batcher = ScoutLogBatcher(
          export: (batch) async {
            exported.add(batch);
            return true;
          },
          interval: const Duration(seconds: 30),
          maxExportBatchSize: 512,
          maxQueueSize: 2048,
        )..start();

        batcher.add(_record('a'));
        batcher.add(_record('b'));
        async.elapse(const Duration(seconds: 29));
        expect(exported, isEmpty, reason: 'nothing exports before the tick');

        async.elapse(const Duration(seconds: 2));
        expect(exported, hasLength(1));
        expect(exported.single.map((r) => r.body), ['a', 'b']);

        batcher.stop();
      });
    });

    test('flushes immediately when the batch size cap is reached', () {
      fakeAsync((async) {
        final exported = <List<ScoutLogRecord>>[];
        final batcher = ScoutLogBatcher(
          export: (batch) async {
            exported.add(batch);
            return true;
          },
          interval: const Duration(seconds: 30),
          maxExportBatchSize: 3,
          maxQueueSize: 2048,
        )..start();

        batcher.add(_record('a'));
        batcher.add(_record('b'));
        expect(exported, isEmpty);
        batcher.add(_record('c'));
        async.flushMicrotasks();

        expect(exported, hasLength(1));
        expect(exported.single, hasLength(3));

        batcher.stop();
      });
    });

    test('drops logs beyond maxQueueSize', () {
      fakeAsync((async) {
        final exported = <List<ScoutLogRecord>>[];
        final batcher = ScoutLogBatcher(
          export: (batch) async {
            exported.add(batch);
            return true;
          },
          interval: const Duration(seconds: 30),
          maxExportBatchSize: 512,
          maxQueueSize: 5,
        )..start();

        for (var i = 0; i < 10; i++) {
          batcher.add(_record('log-$i'));
        }
        async.elapse(const Duration(seconds: 31));

        final total = exported.expand((b) => b).length;
        expect(total, 5);

        batcher.stop();
      });
    });

    test('splits an oversized buffer into batch-size chunks', () {
      fakeAsync((async) {
        final exported = <List<ScoutLogRecord>>[];
        final batcher = ScoutLogBatcher(
          export: (batch) async {
            exported.add(batch);
            return true;
          },
          interval: const Duration(seconds: 30),
          maxExportBatchSize: 4,
          maxQueueSize: 2048,
        );
        // no start() — fill then flush manually so nothing auto-flushes
        for (var i = 0; i < 10; i++) {
          batcher.add(_record('log-$i'));
        }
        // adding the 4th triggers a size-flush; drain everything manually
        batcher.flush();
        async.flushMicrotasks();

        expect(exported.expand((b) => b).length, 10);
        for (final batch in exported) {
          expect(batch.length, lessThanOrEqualTo(4));
        }
      });
    });

    test('hands failed batches to onExportFailed and never re-sends them', () {
      fakeAsync((async) {
        final exported = <List<ScoutLogRecord>>[];
        final failed = <List<ScoutLogRecord>>[];
        var succeed = false;
        final batcher = ScoutLogBatcher(
          export: (batch) async {
            if (!succeed) return false;
            exported.add(batch);
            return true;
          },
          onExportFailed: failed.add,
          interval: const Duration(seconds: 30),
          maxExportBatchSize: 512,
          maxQueueSize: 2048,
        )..start();

        batcher.add(_record('a'));
        async.elapse(const Duration(seconds: 31));

        expect(failed, hasLength(1));
        expect(exported, isEmpty);

        // Next interval: buffer is empty, the failed batch must not resend.
        succeed = true;
        async.elapse(const Duration(seconds: 31));
        expect(exported, isEmpty);

        batcher.stop();
      });
    });

    test('manual flush exports whatever is buffered (app pause path)', () {
      fakeAsync((async) {
        final exported = <List<ScoutLogRecord>>[];
        final batcher = ScoutLogBatcher(
          export: (batch) async {
            exported.add(batch);
            return true;
          },
          interval: const Duration(seconds: 30),
          maxExportBatchSize: 512,
          maxQueueSize: 2048,
        )..start();

        batcher.add(_record('a'));
        batcher.flush();
        async.flushMicrotasks();

        expect(exported, hasLength(1));

        batcher.stop();
      });
    });
  });
}
