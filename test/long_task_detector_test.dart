import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/long_task_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LongTaskDetector', () {
    test('can be instantiated with default threshold', () {
      final detector = LongTaskDetector(onLongTask: (_) {});
      expect(detector.threshold, const Duration(milliseconds: 100));
      expect(detector.isRunning, isFalse);
    });

    test('can be instantiated with custom threshold', () {
      final detector = LongTaskDetector(
        threshold: const Duration(milliseconds: 50),
        onLongTask: (_) {},
      );
      expect(detector.threshold, const Duration(milliseconds: 50));
    });

    test('detects a long task when event loop is blocked', () async {
      final detected = <Duration>[];
      final detector = LongTaskDetector(
        threshold: const Duration(milliseconds: 50),
        onLongTask: (d) => detected.add(d),
      );

      detector.start();
      expect(detector.isRunning, isTrue);

      // Let the polling loop run a couple of iterations to establish a baseline.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Busy-wait to block the event loop for longer than the threshold.
      final blockUntil =
          DateTime.now().millisecondsSinceEpoch + 120; // block ~120ms
      while (DateTime.now().millisecondsSinceEpoch < blockUntil) {
        // busy wait
      }

      // Give the polling loop a chance to measure the blocked time.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      await detector.stop();
      expect(detector.isRunning, isFalse);

      expect(detected, isNotEmpty);
      expect(detected.first.inMilliseconds, greaterThan(50));
    });

    test(
      'does NOT report when event loop is not blocked beyond threshold',
      () async {
        final detected = <Duration>[];
        final detector = LongTaskDetector(
          threshold: const Duration(milliseconds: 200),
          onLongTask: (d) => detected.add(d),
        );

        detector.start();

        // Let several polling iterations pass without blocking.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        await detector.stop();

        expect(detected, isEmpty);
      },
    );

    test('can be stopped and no further detections occur', () async {
      final detected = <Duration>[];
      final detector = LongTaskDetector(
        threshold: const Duration(milliseconds: 50),
        onLongTask: (d) => detected.add(d),
      );

      detector.start();
      await detector.stop();

      // Block the event loop after stopping — should NOT be reported.
      final blockUntil = DateTime.now().millisecondsSinceEpoch + 120;
      while (DateTime.now().millisecondsSinceEpoch < blockUntil) {
        // busy wait
      }

      // Give any hypothetical pending futures a chance to run.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(detected, isEmpty);
    });
  });
}
