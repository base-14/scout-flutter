import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_debug_logger.dart';

void main() {
  late List<String> captured;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    captured = <String>[];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
  });

  group('ScoutDebugLogger disabled', () {
    final logger = const ScoutDebugLogger(enabled: false);

    test('init emits nothing', () {
      logger.init(
        serviceName: 'svc',
        endpoint: 'e',
        version: '1.0',
        sampleRate: 1.0,
        alwaysCaptureErrors: true,
      );
      expect(captured, isEmpty);
    });

    test('session, sample, exportBatch, log, error emit nothing', () {
      logger.session(sessionId: 'sid', sampled: true);
      logger.sample(name: 'span', decision: 'drop');
      logger.exportBatch(spans: 3, durationMs: 10, ok: true);
      logger.log(level: 'info', message: 'msg');
      logger.error('boom');
      expect(captured, isEmpty);
    });
  });

  group('ScoutDebugLogger enabled', () {
    final logger = const ScoutDebugLogger(enabled: true);

    test('init prints all fields', () {
      logger.init(
        serviceName: 'my-app',
        endpoint: 'http://localhost:4318',
        version: '1.0.0',
        sampleRate: 1.0,
        alwaysCaptureErrors: true,
      );
      expect(captured, hasLength(1));
      expect(captured.first, contains('[scout] init ok'));
      expect(captured.first, contains('service=my-app'));
      expect(captured.first, contains('endpoint=http://localhost:4318'));
      expect(captured.first, contains('v=1.0.0'));
      expect(captured.first, contains('sampleRate=1.0'));
      expect(captured.first, contains('alwaysCaptureErrors=true'));
    });

    test('session prints id and sampled flag', () {
      logger.session(sessionId: 'a1b2c3', sampled: true);
      expect(captured.first, '[scout] session a1b2c3 sampled=true');
    });

    test('sample prints span name and decision', () {
      logger.sample(name: 'screen_view', decision: 'recordAndSample');
      expect(captured.first, '[scout] span screen_view → recordAndSample');
    });

    test('exportBatch ok format', () {
      logger.exportBatch(spans: 8, durationMs: 212, ok: true);
      expect(captured.first, '[scout] export batch: 8 spans (212ms) ok');
    });

    test('exportBatch failure includes error', () {
      logger.exportBatch(spans: 2, durationMs: 50, ok: false, error: 'timeout');
      expect(
        captured.first,
        '[scout] export batch: 2 spans (50ms) FAILED (timeout)',
      );
    });

    test('log prints level and message', () {
      logger.log(level: 'warn', message: 'Retry attempt 2');
      expect(captured.first, '[scout] log [warn] Retry attempt 2');
    });

    test('log truncates messages longer than 80 chars', () {
      final long = 'x' * 200;
      logger.log(level: 'info', message: long);
      expect(captured.first, endsWith('...'));
      expect(captured.first.length, lessThan(100));
    });

    test('error prints prefix and message', () {
      logger.error('export failed');
      expect(captured.first, '[scout] error: export failed');
    });
  });
}
