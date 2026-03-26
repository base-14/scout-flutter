import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/offline_queue.dart';

void main() {
  late Directory tempDir;
  late OfflineQueue queue;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scout_test_');
    queue = OfflineQueue(directory: tempDir, maxStorageMb: 1);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('OfflineQueue', () {
    test('enqueue writes a file', () async {
      await queue.enqueue('spans', [
        {'type': 'span', 'name': 'test_span'}
      ]);
      final files = tempDir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.first.path, contains('spans_'));
    });

    test('dequeueAll reads and deletes files', () async {
      await queue.enqueue('spans', [
        {'name': 'span1'}
      ]);
      await queue.enqueue('metrics', [
        {'name': 'metric1'}
      ]);
      final batches = await queue.dequeueAll();
      expect(batches, hasLength(2));
      final files = tempDir.listSync().whereType<File>().toList();
      expect(files, isEmpty);
    });

    test('enforces storage cap by deleting oldest files', () async {
      final largeBatch =
          List.generate(5000, (i) => {'key': 'value_$i', 'data': 'x' * 200});
      await queue.enqueue('spans', largeBatch);
      await queue.enqueue('spans', largeBatch);
      await queue.enqueue('spans', largeBatch);
      await queue.enforceStorageCap();
      final totalSize = tempDir
          .listSync()
          .whereType<File>()
          .fold<int>(0, (sum, f) => sum + f.lengthSync());
      expect(totalSize, lessThanOrEqualTo(1 * 1024 * 1024));
    });

    test('dequeueAll returns empty list when no files', () async {
      final batches = await queue.dequeueAll();
      expect(batches, isEmpty);
    });

    test('batch roundtrip preserves data', () async {
      final original = [
        {'type': 'span', 'name': 'test', 'value': 42}
      ];
      await queue.enqueue('spans', original);
      final batches = await queue.dequeueAll();
      expect(batches.first.signal, 'spans');
      expect(batches.first.events, equals(original));
    });
  });
}
