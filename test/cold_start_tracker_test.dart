import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/cold_start_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ColdStartTracker tracker({
    required List<ColdStartResult> sink,
    int? nativeStartMs,
    int nowMs = 1000000,
    bool throwOnNative = false,
  }) {
    return ColdStartTracker(
      onColdStart: sink.add,
      processStartMs: () async {
        if (throwOnNative) throw StateError('channel down');
        return nativeStartMs;
      },
      nowEpochMs: () => nowMs,
    );
  }

  group('ColdStartTracker.resolve', () {
    test('uses the process start when present and plausible', () {
      final r = ColdStartTracker.resolve(
        nativeStartMs: 995000,
        firstFrameAtMs: 1000000,
        fallbackElapsed: const Duration(milliseconds: 300),
      );
      expect(r.durationMs, 5000);
      expect(r.anchor, 'process_start');
    });

    test('falls back to the SDK-init stopwatch when native is null', () {
      final r = ColdStartTracker.resolve(
        nativeStartMs: null,
        firstFrameAtMs: 1000000,
        fallbackElapsed: const Duration(milliseconds: 300),
      );
      expect(r.durationMs, 300);
      expect(r.anchor, 'sdk_init');
    });

    test('rejects a process start older than the plausibility cap', () {
      final r = ColdStartTracker.resolve(
        nativeStartMs: 1000000 - 120000,
        firstFrameAtMs: 1000000,
        fallbackElapsed: const Duration(milliseconds: 300),
      );
      expect(r.anchor, 'sdk_init');
      expect(r.durationMs, 300);
    });

    test('rejects a process start in the future', () {
      final r = ColdStartTracker.resolve(
        nativeStartMs: 1000500,
        firstFrameAtMs: 1000000,
        fallbackElapsed: const Duration(milliseconds: 300),
      );
      expect(r.anchor, 'sdk_init');
    });

    test('accepts exactly the cap', () {
      final r = ColdStartTracker.resolve(
        nativeStartMs: 1000000 - ColdStartTracker.defaultMaxPlausibleMs,
        firstFrameAtMs: 1000000,
        fallbackElapsed: Duration.zero,
      );
      expect(r.anchor, 'process_start');
    });
  });

  group('ColdStartResult', () {
    test('durationSeconds is the millisecond value / 1000', () {
      const r = ColdStartResult(durationMs: 1500, anchor: 'process_start');
      expect(r.durationSeconds, 1.5);
    });
  });

  group('ColdStartTracker emission', () {
    test('emits once both the first frame and ready have happened', () async {
      final sink = <ColdStartResult>[];
      final t = tracker(sink: sink, nativeStartMs: 995000);
      t.markFirstFrame();
      expect(sink, isEmpty, reason: 'exporter not ready yet');
      await t.ready();
      expect(sink, hasLength(1));
      expect(sink.single.durationMs, 5000);
      expect(sink.single.anchor, 'process_start');
    });

    test('order independence: ready before the first frame', () async {
      final sink = <ColdStartResult>[];
      final t = tracker(sink: sink, nativeStartMs: 995000);
      await t.ready();
      expect(sink, isEmpty, reason: 'no frame rendered yet');
      t.markFirstFrame();
      expect(sink, hasLength(1));
      expect(sink.single.durationMs, 5000);
    });

    test('native null falls back to the stopwatch', () async {
      final sink = <ColdStartResult>[];
      final t = tracker(sink: sink, nativeStartMs: null);
      t.markFirstFrame();
      await t.ready();
      expect(sink.single.anchor, 'sdk_init');
      expect(sink.single.durationMs, greaterThanOrEqualTo(0));
    });

    test('a throwing native provider falls back to the stopwatch', () async {
      final sink = <ColdStartResult>[];
      final t = tracker(sink: sink, throwOnNative: true);
      t.markFirstFrame();
      await t.ready();
      expect(sink.single.anchor, 'sdk_init');
    });

    test('emits exactly once across repeated calls', () async {
      final sink = <ColdStartResult>[];
      final t = tracker(sink: sink, nativeStartMs: 995000);
      t.markFirstFrame();
      t.markFirstFrame();
      await t.ready();
      await t.ready();
      t.markFirstFrame();
      expect(sink, hasLength(1));
      expect(t.isRecorded, isTrue);
    });

    testWidgets('armFirstFrame captures the real post-frame callback once', (
      tester,
    ) async {
      final sink = <ColdStartResult>[];
      final t = tracker(sink: sink, nativeStartMs: 995000);
      t.armFirstFrame();
      t.armFirstFrame();
      await t.ready();
      expect(sink, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(sink, hasLength(1));
      expect(t.firstFrameAtMs, 1000000);
    });
  });
}
