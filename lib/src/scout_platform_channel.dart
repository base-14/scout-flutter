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
    await _channel.invokeMethod('simulateAnr', {'durationMs': durationMs});
  }

  static Future<Map<String, dynamic>> getMemoryUsage() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getMemoryUsage',
    );
    return result ?? {};
  }

  static Future<Map<String, dynamic>> getCpuUsage() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getCpuUsage',
    );
    return result ?? {};
  }

  /// Retrieve pending native crash reports from the previous session.
  ///
  /// Returns a list of crash report maps, each with keys:
  /// - `crash_type`: "jvm_exception", "native_signal", "mach", "signal", etc.
  /// - `crash_reason`: exception message or signal name
  /// - `crash_timestamp`: ISO 8601 timestamp
  /// - `crash_thread_name`: thread that crashed
  /// - `crash_stack_trace`: stack trace string
  static Future<List<Map<String, dynamic>>> getNativeCrashReports() async {
    final result = await _channel.invokeListMethod<Map>(
      'getNativeCrashReports',
    );
    if (result == null) return [];
    return result.map((r) => Map<String, dynamic>.from(r)).toList();
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
