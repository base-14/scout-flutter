import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/frame_metrics_collector.dart';

void main() {
  group('FrameMetricsCollector', () {
    test('can be instantiated', () {
      final collector = FrameMetricsCollector(
        onFrameTiming: (_, __) {},
      );
      expect(collector.isCollecting, false);
    });

    test('isCollecting is true after start', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final collector = FrameMetricsCollector(
        onFrameTiming: (_, __) {},
      );
      collector.start();
      expect(collector.isCollecting, true);
      collector.stop();
    });

    test('isCollecting is false after stop', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final collector = FrameMetricsCollector(
        onFrameTiming: (_, __) {},
      );
      collector.start();
      collector.stop();
      expect(collector.isCollecting, false);
    });

    test('does not double-start', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final collector = FrameMetricsCollector(
        onFrameTiming: (_, __) {},
      );
      collector.start();
      collector.start(); // should be no-op
      expect(collector.isCollecting, true);
      collector.stop();
    });

    test('frozen frame threshold defaults to 700ms', () {
      final collector = FrameMetricsCollector(
        onFrameTiming: (_, __) {},
      );
      expect(collector.frozenFrameThreshold, const Duration(milliseconds: 700));
    });
  });
}
