import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_logger.dart';

void main() {
  group('ScoutLogger', () {
    late ScoutLogger logger;
    late List<ScoutLogEntry> capturedLogs;

    setUp(() {
      capturedLogs = [];
      logger = ScoutLogger(onLog: (entry) => capturedLogs.add(entry));
    });

    test('log records message with correct level', () {
      logger.log(LogLevel.info, 'test message');
      expect(capturedLogs, hasLength(1));
      expect(capturedLogs.first.level, LogLevel.info);
      expect(capturedLogs.first.message, 'test message');
    });

    test('logDebug uses debug level', () {
      logger.logDebug('debug msg');
      expect(capturedLogs.first.level, LogLevel.debug);
    });

    test('logInfo uses info level', () {
      logger.logInfo('info msg');
      expect(capturedLogs.first.level, LogLevel.info);
    });

    test('logWarning uses warning level', () {
      logger.logWarning('warn msg');
      expect(capturedLogs.first.level, LogLevel.warning);
    });

    test('logError uses error level', () {
      logger.logError('error msg');
      expect(capturedLogs.first.level, LogLevel.error);
    });

    test('log includes attributes when provided', () {
      logger.log(LogLevel.info, 'msg', attributes: {'key': 'value'});
      expect(capturedLogs.first.attributes, {'key': 'value'});
    });

    test('log includes timestamp', () {
      final before = DateTime.now();
      logger.log(LogLevel.info, 'msg');
      final after = DateTime.now();
      final ts = capturedLogs.first.timestamp;
      expect(!ts.isBefore(before), isTrue);
      expect(!ts.isAfter(after), isTrue);
    });

    test('LogLevel severity numbers match OTel spec', () {
      expect(LogLevel.debug.severityNumber, 5);
      expect(LogLevel.info.severityNumber, 9);
      expect(LogLevel.warning.severityNumber, 13);
      expect(LogLevel.error.severityNumber, 17);
    });
  });
}
