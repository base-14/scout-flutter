import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';
import 'package:scout_flutter/src/crash_detector.dart';
import 'package:scout_flutter/src/scout_debug_logger.dart';
import 'package:scout_flutter/src/scout_enabled_gate.dart';
import 'package:scout_flutter/src/scout_sample_gate.dart';
import 'package:scout_flutter/src/scout_session_sampler.dart'
    show kErrorClassSpans;
import 'package:scout_flutter/src/session_manager.dart';

/// Unit tests for the runtime kill switch (`enabled` / `setEnabled`), one
/// group per rule of the spec. The end-to-end behaviour through
/// `ScoutFlutter.initialize` is in runtime_enable_simulation_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('scout_enable');
  });
  tearDown(() async {
    ScoutFlutter.resetForTesting();
    await dir.delete(recursive: true);
  });

  group('config and public API', () {
    test('enabled defaults to true', () {
      const c = ScoutFlutterConfig(serviceName: 's', endpoint: 'e');
      expect(c.enabled, isTrue);
      expect(
        const ScoutFlutterConfig(
          serviceName: 's',
          endpoint: 'e',
          enabled: false,
        ).enabled,
        isFalse,
      );
    });

    test('isEnabled is true before initialize', () {
      expect(ScoutFlutter.isEnabled, isTrue);
    });

    test('a pre-init setEnabled is held and readable', () {
      ScoutFlutter.setEnabled(false);
      expect(ScoutFlutter.isEnabled, isFalse);
      ScoutFlutter.setEnabled(true);
      expect(ScoutFlutter.isEnabled, isTrue);
    });
  });

  group('rule 1: nothing leaves the device, errors included', () {
    var enabled = true;
    final sm = SessionManager(sampleRate: 100);
    ScoutSampleGate gate({bool alwaysCaptureErrors = true}) => ScoutSampleGate(
      sessionResolver: () => sm,
      alwaysCaptureErrors: alwaysCaptureErrors,
      enabledResolver: () => enabled,
    );

    setUp(() => enabled = true);

    test('the gate drops every signal while disabled', () {
      enabled = false;
      final g = gate();
      expect(g.shouldSampleSpan('screen_view'), isFalse);
      expect(g.shouldSampleMetric(), isFalse);
      expect(g.shouldSampleLog(isError: false), isFalse);
    });

    test('errors are dropped despite alwaysCaptureErrors', () {
      enabled = false;
      final g = gate(alwaysCaptureErrors: true);
      for (final name in kErrorClassSpans) {
        expect(g.shouldSampleSpan(name), isFalse, reason: name);
      }
      expect(g.shouldSampleLog(isError: true), isFalse);
    });

    test('the gate is unchanged while enabled', () {
      final g = gate();
      expect(g.shouldSampleSpan('screen_view'), isTrue);
      expect(g.shouldSampleMetric(), isTrue);
      expect(g.shouldSampleLog(isError: false), isTrue);
    });

    test('a closed metric exporter sends nothing', () async {
      final inner = _CountingMetricExporter();
      final gated = EnabledGatedMetricExporter(inner, open: false);
      expect(await gated.export(MetricData.empty()), isTrue);
      expect(await gated.forceFlush(), isTrue);
      expect(inner.exports, 0);
      expect(inner.flushes, 0);
      gated.open = true;
      await gated.export(MetricData.empty());
      expect(inner.exports, 1);
    });
  });

  group('rule 2: nothing is buffered for later', () {
    test(
      'a span ending while disabled never reaches the batch queue',
      () async {
        var enabled = true;
        final inner = _RecordingSpanProcessor();
        final p = EnabledGatedSpanProcessor(inner, isEnabled: () => enabled);
        await OTel.initialize(
          serviceName: 'enable-test',
          endpoint: 'http://127.0.0.1:9',
        );
        addTearDown(() async {
          // ignore: invalid_use_of_visible_for_testing_member
          await OTel.reset();
        });
        final span = OTel.tracer().startSpan('s')..end();
        await p.onEnd(span);
        expect(inner.ended, 1);
        enabled = false;
        await p.onEnd(span);
        expect(inner.ended, 1, reason: 'dropped, not queued');
        enabled = true;
        await p.forceFlush();
        expect(inner.ended, 1, reason: 'nothing from the disabled period');
      },
    );
  });

  group('rule 3: crashes while disabled are never reported later', () {
    test('ending the session removes the crash marker', () async {
      final detector = CrashDetector(directory: dir);
      await detector.markSessionStarted(sessionId: 's1');
      await detector.markSessionEnded();
      expect(await detector.checkPreviousCrash(), isNull);
    });

    test('an enabled run\'s marker survives until checked', () async {
      final detector = CrashDetector(directory: dir);
      await detector.markSessionStarted(sessionId: 's1');
      final report = await detector.checkPreviousCrash();
      expect(report?.sessionId, 's1');
    });

    test('exit-info deaths from the disabled period are dropped', () {
      final records = [
        {'crash_type': 'anr', 'crash_death_timestamp_ms': 1000},
        {'crash_type': 'anr', 'crash_death_timestamp_ms': 2000},
        {'crash_type': 'anr', 'crash_death_timestamp_ms': 3000},
      ];
      final kept = ScoutFlutter.dropDisabledPeriodExitInfo(records, 2000);
      expect(kept.map((r) => r['crash_death_timestamp_ms']), [1000]);
      expect(ScoutFlutter.dropDisabledPeriodExitInfo(records, null), records);
    });
  });

  group('rule 4: no session is created, resumed or extended', () {
    test(
      'start(resume: false) mints a new session over a live record',
      () async {
        final first = SessionManager(sampleRate: 100);
        await first.start(directory: dir);
        await _settle();
        final second = SessionManager(sampleRate: 100);
        await second.start(directory: dir, resume: false);
        await _settle();
        expect(second.sessionId, isNot(first.sessionId));
        final stored = _record(dir);
        expect(stored['id'], second.sessionId);
      },
    );

    test('start() still resumes a live record', () async {
      final first = SessionManager(sampleRate: 100);
      await first.start(directory: dir);
      await _settle();
      final second = SessionManager(sampleRate: 100);
      await second.start(directory: dir);
      expect(second.sessionId, first.sessionId);
    });

    test('end() removes the record and stops all writes', () async {
      final sm = SessionManager(sampleRate: 100);
      await sm.start(directory: dir);
      await _settle();
      await sm.end();
      expect(sm.isEnded, isTrue);
      expect(File('${dir.path}/scout_session.json').existsSync(), isFalse);
      sm.onBackground();
      sm.onForeground();
      sm.rotateSession();
      await _settle();
      expect(File('${dir.path}/scout_session.json').existsSync(), isFalse);
    });

    test('end() leaves a newer session\'s record alone', () async {
      final old = SessionManager(sampleRate: 100);
      await old.start(directory: dir);
      await _settle();
      final fresh = SessionManager(sampleRate: 100);
      await fresh.start(directory: dir, resume: false);
      await _settle();
      await old.end();
      expect(_record(dir)['id'], fresh.sessionId);
    });
  });

  group('rule 6 and debug logging', () {
    test('sessionId is null while disabled', () {
      ScoutFlutter.setEnabled(false);
      expect(ScoutFlutter.sessionId, isNull);
    });

    test('the debug logger prints the state', () {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        const ScoutDebugLogger(enabled: true).rumEnabled(false, reason: 'init');
        const ScoutDebugLogger(
          enabled: false,
        ).rumEnabled(true, reason: 'setEnabled');
      } finally {
        debugPrint = original;
      }
      expect(lines, ['[scout] enabled=false (init)']);
    });
  });
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

Map<String, dynamic> _record(Directory dir) =>
    json.decode(File('${dir.path}/scout_session.json').readAsStringSync())
        as Map<String, dynamic>;

class _RecordingSpanProcessor implements SpanProcessor {
  int ended = 0;

  @override
  Future<void> onStart(Span span, Context? parentContext) async {}

  @override
  Future<void> onEnd(Span span) async => ended++;

  @override
  Future<void> onNameUpdate(Span span, String newName) async {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

class _CountingMetricExporter implements MetricExporter {
  int exports = 0;
  int flushes = 0;

  @override
  Future<bool> export(MetricData data) async {
    exports++;
    return true;
  }

  @override
  Future<bool> forceFlush() async {
    flushes++;
    return true;
  }

  @override
  Future<bool> shutdown() async => true;
}
