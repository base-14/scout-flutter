import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

Map<String, dynamic> _record(String type, {int? deathTsMs}) => {
  'crash_type': type,
  'crash_reason': 'reason',
  if (deathTsMs != null) 'crash_death_timestamp_ms': deathTsMs,
};

void main() {
  group('isCrashClassExitInfo', () {
    test('crash-class exit reasons are emitted', () {
      for (final type in const [
        'anr',
        'jvm_crash',
        'native_crash',
        'low_memory',
      ]) {
        expect(ScoutFlutter.isCrashClassExitInfo(type), isTrue, reason: type);
      }
    });

    test('benign exit reasons are not crashes', () {
      for (final type in const [
        'user_requested', // swiped from recents / ANR-dialog close
        'user_stopped', // Force Stop in settings
        'exit_self', // app called exit() normally
        'signaled',
        'permission_change',
        'excessive_resources',
        'init_failure',
        'dependency_died',
        'other',
        'unknown',
      ]) {
        expect(ScoutFlutter.isCrashClassExitInfo(type), isFalse, reason: type);
      }
      expect(ScoutFlutter.isCrashClassExitInfo(null), isFalse);
    });
  });

  group('selectNewExitInfoRecords', () {
    test('null watermark emits everything (first run after install)', () {
      final records = [
        _record('jvm_crash', deathTsMs: 100),
        _record('anr', deathTsMs: 200),
      ];
      final selected = ScoutFlutter.selectNewExitInfoRecords(records, null);
      expect(selected, hasLength(2));
    });

    test('records at or below the watermark are not re-emitted', () {
      final records = [
        _record('jvm_crash', deathTsMs: 100),
        _record('anr', deathTsMs: 200),
        _record('native_crash', deathTsMs: 300),
      ];
      final selected = ScoutFlutter.selectNewExitInfoRecords(records, 200);
      expect(selected, hasLength(1));
      expect(selected.single['crash_death_timestamp_ms'], 300);
    });

    test('second drain with unchanged history emits nothing', () {
      final records = [
        _record('jvm_crash', deathTsMs: 100),
        _record('anr', deathTsMs: 200),
      ];
      final watermark = ScoutFlutter.exitInfoWatermarkOf(records);
      expect(watermark, 200);
      final again = ScoutFlutter.selectNewExitInfoRecords(records, watermark);
      expect(again, isEmpty);
    });

    test('records without a death timestamp are emitted only on first run', () {
      final records = [_record('jvm_crash')];
      expect(
        ScoutFlutter.selectNewExitInfoRecords(records, null),
        hasLength(1),
      );
      expect(ScoutFlutter.selectNewExitInfoRecords(records, 0), isEmpty);
    });
  });
}
