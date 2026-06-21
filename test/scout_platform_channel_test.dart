import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.base14.scout_flutter');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'getMemoryUsage') {
            return {'used': 100000, 'max': 500000};
          }
          if (call.method == 'getCpuUsage') {
            return {'cpu_percent': 42.0};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('ScoutPlatformChannel', () {
    test('startAnrDetection sends correct method and args', () async {
      await ScoutPlatformChannel.startAnrDetection(thresholdMs: 3000);

      expect(calls, hasLength(1));
      expect(calls.first.method, 'startAnrDetection');
      expect(calls.first.arguments, {'thresholdMs': 3000});
    });

    test('stopAnrDetection sends correct method', () async {
      await ScoutPlatformChannel.stopAnrDetection();

      expect(calls, hasLength(1));
      expect(calls.first.method, 'stopAnrDetection');
    });

    test('getMemoryUsage returns platform data', () async {
      final result = await ScoutPlatformChannel.getMemoryUsage();

      expect(result, {'used': 100000, 'max': 500000});
    });

    test('getMemoryUsage returns empty map on null response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return null;
          });

      final result = await ScoutPlatformChannel.getMemoryUsage();
      expect(result, isEmpty);
    });

    test('getCpuUsage returns platform data', () async {
      final result = await ScoutPlatformChannel.getCpuUsage();

      expect(result, {'cpu_percent': 42.0});
    });

    test('getCpuUsage returns empty map on null response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return null;
          });

      final result = await ScoutPlatformChannel.getCpuUsage();
      expect(result, isEmpty);
    });

    test('setAnrHandler receives onAnrDetected calls', () async {
      final detections = <int>[];
      ScoutPlatformChannel.setAnrHandler((durationMs, dump) {
        detections.add(durationMs);
      });

      // Simulate native side sending an ANR event
      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onAnrDetected', 5500),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('com.base14.scout_flutter', message, (_) {});

      expect(detections, [5500]);
    });

    test('setAnrHandler receives thread dump payload', () async {
      int? duration;
      Map<String, dynamic>? received;
      ScoutPlatformChannel.setAnrHandler((durationMs, dump) {
        duration = durationMs;
        received = dump;
      });

      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onAnrDetected', {
          'duration': 6000,
          'main_thread_stack': 'main.dart:1',
          'threads_json': '[]',
          'thread_count': 7,
        }),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('com.base14.scout_flutter', message, (_) {});

      expect(duration, 6000);
      expect(received?['main_thread_stack'], 'main.dart:1');
      expect(received?['thread_count'], 7);
    });

    test('setAnrHandler ignores unknown methods', () async {
      final detections = <int>[];
      ScoutPlatformChannel.setAnrHandler((durationMs, dump) {
        detections.add(durationMs);
      });

      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('unknownMethod', 1234),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('com.base14.scout_flutter', message, (_) {});

      expect(detections, isEmpty);
    });
  });
}
