import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';
import 'package:scout_flutter/src/crash_detector.dart';

Map<String, dynamic> _record(String type, {int? deathTsMs}) => {
  'crash_type': type,
  'crash_reason': 'reason',
  if (deathTsMs != null) 'crash_death_timestamp_ms': deathTsMs,
};

void main() {
  group('isCrashClassExitInfo', () {
    test('crash-class exit reasons are emitted', () {
      for (final type in const ['anr', 'jvm_crash', 'native_crash']) {
        expect(ScoutFlutter.isCrashClassExitInfo(type), isTrue, reason: type);
      }
    });

    test('benign exit reasons are not crashes', () {
      for (final type in const [
        'low_memory', // OS reclaimed a cached process — Play Console agrees
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

  group('isReportedExitInfo', () {
    test('only low_memory earns an app_exit span', () {
      expect(ScoutFlutter.isReportedExitInfo('low_memory'), isTrue);
      for (final type in const [
        'anr',
        'jvm_crash',
        'native_crash',
        'user_requested',
        'exit_self',
        'other',
      ]) {
        expect(ScoutFlutter.isReportedExitInfo(type), isFalse, reason: type);
      }
      expect(ScoutFlutter.isReportedExitInfo(null), isFalse);
    });
  });

  group('selectNewExitInfoRecords', () {
    test('null watermark emits nothing (history predates the SDK)', () {
      final records = [
        _record('jvm_crash', deathTsMs: 100),
        _record('anr', deathTsMs: 200),
      ];
      expect(ScoutFlutter.selectNewExitInfoRecords(records, null), isEmpty);
      // The caller persists this so the NEXT launch reports only new deaths.
      expect(ScoutFlutter.exitInfoWatermarkOf(records), 200);
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

    test('records without a death timestamp are never emitted', () {
      final records = [_record('jvm_crash')];
      expect(ScoutFlutter.selectNewExitInfoRecords(records, null), isEmpty);
      expect(ScoutFlutter.selectNewExitInfoRecords(records, 0), isEmpty);
    });
  });

  Map<String, dynamic> exit(String type, int pid, {int deathTsMs = 1000}) => {
    ..._record(type, deathTsMs: deathTsMs),
    'crash_pid': pid,
    'crash_importance': 400,
  };

  group('reconcileAppCrash', () {
    test('no marker pid keeps the heuristic', () {
      final v = ScoutFlutter.reconcileAppCrash(null, [exit('jvm_crash', 7)]);
      expect(v.emitAppCrash, isTrue);
      expect(v.record, isNull);
    });

    test('no exit-info at all (API < 30, iOS) keeps the heuristic', () {
      final v = ScoutFlutter.reconcileAppCrash(7, const []);
      expect(v.emitAppCrash, isTrue);
      expect(v.confirmedByOs, isFalse);
    });

    test('pid missing from the history keeps the heuristic', () {
      final v = ScoutFlutter.reconcileAppCrash(7, [exit('jvm_crash', 8)]);
      expect(v.emitAppCrash, isTrue);
      expect(v.record, isNull);
    });

    test('crash-class record for the pid confirms the crash', () {
      final v = ScoutFlutter.reconcileAppCrash(7, [
        exit('low_memory', 8),
        exit('jvm_crash', 7),
      ]);
      expect(v.emitAppCrash, isTrue);
      expect(v.confirmedByOs, isTrue);
      expect(v.record!['crash_pid'], 7);
    });

    test('benign record for the pid suppresses app_crash', () {
      for (final type in const ['low_memory', 'user_requested', 'exit_self']) {
        final v = ScoutFlutter.reconcileAppCrash(7, [exit(type, 7)]);
        expect(v.emitAppCrash, isFalse, reason: type);
        expect(v.record!['crash_type'], type);
      }
    });
  });

  group('exitInfoSessionAttributes', () {
    final previous = PreviousSession(
      sessionId: 'sess-prev',
      startedAt: DateTime.utc(2026, 9, 19, 13, 50),
      pid: 7,
      status: 'paused',
    );

    test('record for the previous pid belongs to the previous session', () {
      final attrs = ScoutFlutter.exitInfoSessionAttributes(
        exit('low_memory', 7),
        previous,
      );
      expect(attrs['session.id'], 'sess-prev');
      expect(attrs['session.start_time'], '2026-09-19T13:50:00.000Z');
      expect(attrs['crash.previous_session_id'], 'sess-prev');
    });

    test('older history gets no session at all', () {
      expect(
        ScoutFlutter.exitInfoSessionAttributes(exit('low_memory', 3), previous),
        isEmpty,
      );
      expect(
        ScoutFlutter.exitInfoSessionAttributes(exit('low_memory', 7), null),
        isEmpty,
      );
      final noPid = PreviousSession(
        sessionId: 's',
        startedAt: DateTime.utc(2026),
        status: 'started',
      );
      expect(
        ScoutFlutter.exitInfoSessionAttributes(exit('low_memory', 7), noPid),
        isEmpty,
      );
    });
  });

  group('app_exit attribute shape', () {
    test('flattenCrashRecord + asAppExitAttributes rename crash.* only', () {
      final flat = ScoutFlutter.flattenCrashRecord({
        'crash_type': 'low_memory',
        'crash_reason': 'low memory',
        'crash_timestamp': '2026-09-19T13:54:14.244Z',
        'crash_pid': 15538,
        'crash_importance': 400,
        'crash_tombstone': '',
        'not_a_crash_key': 'x',
      });
      expect(flat, {
        'crash.type': 'low_memory',
        'crash.reason': 'low memory',
        'crash.timestamp': '2026-09-19T13:54:14.244Z',
        'crash.pid': 15538,
        'crash.importance': 400,
      });
      final exitAttrs = ScoutFlutter.asAppExitAttributes({
        ...flat,
        'session.id': 'sess-prev',
        'crash.previous_session_id': 'sess-prev',
      });
      expect(exitAttrs.keys.where((k) => k.startsWith('crash.')), isEmpty);
      expect(exitAttrs['exit.type'], 'low_memory');
      expect(exitAttrs['exit.importance'], 400);
      expect(exitAttrs['exit.previous_session_id'], 'sess-prev');
      expect(exitAttrs['session.id'], 'sess-prev');
    });
  });
}
