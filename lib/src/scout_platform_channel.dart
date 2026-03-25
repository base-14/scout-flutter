import 'package:flutter/services.dart';

class ScoutPlatformChannel {
  static const _channel = MethodChannel('com.base14.scout_flutter');

  static Future<void> startAnrDetection({required int thresholdMs}) async {
    await _channel.invokeMethod('startAnrDetection', {
      'thresholdMs': thresholdMs,
    });
  }

  static Future<void> stopAnrDetection() async {
    await _channel.invokeMethod('stopAnrDetection');
  }

  /// Simulate an ANR by blocking the native main thread.
  /// Only for testing — triggers the ANR watchdog.
  static Future<void> simulateAnr({int durationMs = 6000}) async {
    await _channel.invokeMethod('simulateAnr', {
      'durationMs': durationMs,
    });
  }

  /// Set up handler for ANR events from native side.
  static void setAnrHandler(void Function(int durationMs) onAnr) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAnrDetected') {
        final durationMs = call.arguments as int;
        onAnr(durationMs);
      }
    });
  }
}
