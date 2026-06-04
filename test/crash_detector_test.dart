import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/crash_detector.dart';

void main() {
  group('CrashDetector', () {
    late Directory tmp;
    late CrashDetector detector;
    late File markerFile;
    late File breadcrumbFile;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('scout_crash_detector_test_');
      detector = CrashDetector(directory: tmp);
      markerFile = File('${tmp.path}/session_marker.json');
      breadcrumbFile = File('${tmp.path}/breadcrumbs.json');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('checkPreviousCrash returns null with no marker', () async {
      final report = await detector.checkPreviousCrash();
      expect(report, isNull);
    });

    test(
      'paused marker returns null and breadcrumbs file is preserved',
      () async {
        await detector.markSessionStarted(sessionId: 'sess-1');
        await detector.persistBreadcrumbs(
          '[{"type":"navigation","message":"home"}]',
        );
        await detector.markSessionPaused();

        final report = await detector.checkPreviousCrash();
        expect(report, isNull);
        expect(await markerFile.exists(), isFalse);
        expect(
          await breadcrumbFile.exists(),
          isTrue,
          reason:
              'breadcrumbs.json must survive a paused→relaunch so a delayed '
              'native crash report can still attach context.',
        );
        expect(await breadcrumbFile.readAsString(), contains('navigation'));
      },
    );

    test('started marker returns crash report with breadcrumbs', () async {
      await detector.markSessionStarted(sessionId: 'sess-2');
      await detector.persistBreadcrumbs('[{"type":"error","message":"boom"}]');

      final report = await detector.checkPreviousCrash();
      expect(report, isNotNull);
      expect(report!.sessionId, 'sess-2');
      expect(report.status, 'started');
      expect(report.breadcrumbs, contains('boom'));
      expect(await markerFile.exists(), isFalse);
      expect(
        await breadcrumbFile.exists(),
        isFalse,
        reason:
            'a confirmed crash drains breadcrumbs into the report and '
            'deletes the file so the next session starts fresh.',
      );
    });

    test(
      'paused marker followed by started marker returns the latest crash',
      () async {
        await detector.markSessionStarted(sessionId: 'sess-3');
        await detector.persistBreadcrumbs(
          '[{"type":"navigation","message":"old"}]',
        );
        await detector.markSessionPaused();
        await detector.checkPreviousCrash();

        await detector.markSessionStarted(sessionId: 'sess-4');
        await detector.persistBreadcrumbs(
          '[{"type":"navigation","message":"new"}]',
        );

        final report = await detector.checkPreviousCrash();
        expect(report, isNotNull);
        expect(report!.sessionId, 'sess-4');
        expect(report.breadcrumbs, contains('new'));
      },
    );

    test('updateLastScreen surfaces in the next crash report', () async {
      await detector.markSessionStarted(sessionId: 'sess-5');
      await detector.updateLastScreen('SettingsScreen');
      final marker =
          json.decode(await markerFile.readAsString()) as Map<String, dynamic>;
      expect(marker['last_screen'], 'SettingsScreen');
      final report = await detector.checkPreviousCrash();
      expect(report?.lastScreen, 'SettingsScreen');
    });

    test(
      'consumeOrphanedBreadcrumbs reads + deletes a paused-survivor file',
      () async {
        await detector.markSessionStarted(sessionId: 'sess-6');
        await detector.persistBreadcrumbs(
          '[{"type":"navigation","message":"home"}]',
        );
        await detector.markSessionPaused();
        await detector.checkPreviousCrash();
        expect(
          await breadcrumbFile.exists(),
          isTrue,
          reason: 'paused path must preserve the file',
        );

        final crumbs = await detector.consumeOrphanedBreadcrumbs();
        expect(crumbs, contains('navigation'));
        expect(
          await breadcrumbFile.exists(),
          isFalse,
          reason: 'consume drains the file so a future drain is idempotent',
        );

        final repeat = await detector.consumeOrphanedBreadcrumbs();
        expect(repeat, isNull);
      },
    );

    test('consumeOrphanedBreadcrumbs returns null with no file', () async {
      final crumbs = await detector.consumeOrphanedBreadcrumbs();
      expect(crumbs, isNull);
    });

    test('corrupted marker returns null and clears the marker', () async {
      await markerFile.writeAsString('{not json');
      final report = await detector.checkPreviousCrash();
      expect(report, isNull);
      expect(await markerFile.exists(), isFalse);
    });
  });
}
