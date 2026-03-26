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

    test('simulateAnr sends correct method and default args', () async {
      await ScoutPlatformChannel.simulateAnr();

      expect(calls, hasLength(1));
      expect(calls.first.method, 'simulateAnr');
      expect(calls.first.arguments, {'durationMs': 6000});
    });

    test('simulateAnr sends custom duration', () async {
      await ScoutPlatformChannel.simulateAnr(durationMs: 3000);

      expect(calls.first.arguments, {'durationMs': 3000});
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
      ScoutPlatformChannel.setAnrHandler((durationMs) {
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

    test('setAnrHandler ignores unknown methods', () async {
      final detections = <int>[];
      ScoutPlatformChannel.setAnrHandler((durationMs) {
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
