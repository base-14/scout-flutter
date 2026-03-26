import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/offline_queue.dart';
import 'package:scout_flutter/src/enhanced_exporter.dart';

void main() {
  late Directory tempDir;
  late OfflineQueue queue;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scout_exporter_test_');
    queue = OfflineQueue(directory: tempDir, maxStorageMb: 1);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('EnhancedExporter', () {
    test('passes through when inner export succeeds', () async {
      var exported = false;
      final exporter = EnhancedExporter(
        innerExport: (_) async {
          exported = true;
          return true;
        },
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
      );
      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isTrue);
      expect(exported, isTrue);
    });

    test('returns true without exporting when not sampled', () async {
      var exported = false;
      final exporter = EnhancedExporter(
        innerExport: (_) async {
          exported = true;
          return true;
        },
        isSampled: () => false,
        queue: queue,
        signal: 'spans',
      );
      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isTrue);
      expect(exported, isFalse);
    });

    test('queues to offline when inner export fails', () async {
      final exporter = EnhancedExporter(
        innerExport: (_) async => false,
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
      );
      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isFalse);
      final batches = await queue.dequeueAll();
      expect(batches, hasLength(1));
      expect(batches.first.signal, 'spans');
    });

    test('applies beforeSend filter — drops nulls, modifies events', () async {
      final exported = <List<Map<String, dynamic>>>[];
      final exporter = EnhancedExporter(
        innerExport: (events) async {
          exported.add(events);
          return true;
        },
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
        beforeSend: (event) {
          if (event['name'] == 'drop_me') return null;
          event['modified'] = true;
          return event;
        },
      );
      await exporter.export([
        {'name': 'keep_me'},
        {'name': 'drop_me'},
      ]);
      expect(exported.first, hasLength(1));
      expect(exported.first.first['name'], 'keep_me');
      expect(exported.first.first['modified'], isTrue);
    });

    test('returns true for empty events list', () async {
      var exported = false;
      final exporter = EnhancedExporter(
        innerExport: (_) async {
          exported = true;
          return true;
        },
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
      );
      final result = await exporter.export([]);
      expect(result, isTrue);
      expect(exported, isFalse);
    });

    test('returns true when beforeSend drops all events', () async {
      var exported = false;
      final exporter = EnhancedExporter(
        innerExport: (_) async {
          exported = true;
          return true;
        },
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
        beforeSend: (event) => null, // drop everything
      );
      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isTrue);
      expect(exported, isFalse);
    });
  });
}
