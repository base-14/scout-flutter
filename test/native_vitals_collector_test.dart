import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/native_vitals_collector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.base14.scout_flutter');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'getMemoryUsage') {
            return {'used': 50000000, 'max': 200000000};
          }
          if (call.method == 'getCpuUsage') {
            return {'cpu_percent': 25.5};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('NativeVitalsCollector', () {
    test('can be instantiated', () {
      final collector = NativeVitalsCollector(
        onMemory: (_, __) {},
        onCpu: (_) {},
      );
      expect(collector.isCollecting, false);
    });

    test('isCollecting is true after start', () {
      final collector = NativeVitalsCollector(
        onMemory: (_, __) {},
        onCpu: (_) {},
      );
      collector.start();
      expect(collector.isCollecting, true);
      collector.stop();
    });

    test('isCollecting is false after stop', () {
      final collector = NativeVitalsCollector(
        onMemory: (_, __) {},
        onCpu: (_) {},
      );
      collector.start();
      collector.stop();
      expect(collector.isCollecting, false);
    });

    test('collects memory data from platform channel', () async {
      final memoryData = <List<int>>[];
      final collector = NativeVitalsCollector(
        interval: const Duration(milliseconds: 50),
        onMemory: (used, max) => memoryData.add([used, max]),
        onCpu: (_) {},
      );

      collector.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      collector.stop();

      expect(memoryData, isNotEmpty);
      expect(memoryData.first[0], 50000000);
      expect(memoryData.first[1], 200000000);
    });

    test('collects CPU data from platform channel (iOS cpu_percent)', () async {
      final cpuData = <double>[];
      final collector = NativeVitalsCollector(
        interval: const Duration(milliseconds: 50),
        onMemory: (_, __) {},
        onCpu: (percent) => cpuData.add(percent),
      );

      collector.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      collector.stop();

      expect(cpuData, isNotEmpty);
      expect(cpuData.first, 25.5);
    });

    test('computes CPU from ticks delta on Android', () async {
      int callCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'getMemoryUsage') {
              return {'used': 50000000, 'max': 200000000};
            }
            if (call.method == 'getCpuUsage') {
              callCount++;
              // Simulate increasing ticks (100 tick-ms per interval)
              return {'ticks': callCount * 100};
            }
            return null;
          });

      final cpuData = <double>[];
      final collector = NativeVitalsCollector(
        interval: const Duration(milliseconds: 50),
        onMemory: (_, __) {},
        onCpu: (percent) => cpuData.add(percent),
      );

      collector.start();
      // Need at least 2 polls for delta computation
      await Future<void>.delayed(const Duration(milliseconds: 180));
      collector.stop();

      // First poll has no delta, second+ should have computed CPU
      expect(cpuData, isNotEmpty);
    });

    test('handles platform channel errors gracefully', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(code: 'ERROR', message: 'test error');
          });

      final collector = NativeVitalsCollector(
        interval: const Duration(milliseconds: 50),
        onMemory: (_, __) {},
        onCpu: (_) {},
      );

      // Should not throw
      collector.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      collector.stop();
    });

    test('skips memory callback when used is <= 0', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'getMemoryUsage') {
              return {'used': -1, 'max': -1};
            }
            if (call.method == 'getCpuUsage') {
              return {'cpu_percent': 10.0};
            }
            return null;
          });

      final memoryData = <List<int>>[];
      final collector = NativeVitalsCollector(
        interval: const Duration(milliseconds: 50),
        onMemory: (used, max) => memoryData.add([used, max]),
        onCpu: (_) {},
      );

      collector.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      collector.stop();

      expect(memoryData, isEmpty);
    });

    test('default interval is 500ms', () {
      final collector = NativeVitalsCollector(
        onMemory: (_, __) {},
        onCpu: (_) {},
      );
      expect(collector.interval, const Duration(milliseconds: 500));
    });
  });
}
