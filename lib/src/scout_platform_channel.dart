import 'package:flutter/services.dart';

class ScoutPlatformChannel {
  static const _channel = MethodChannel('com.base14.scout_flutter');

  // Multi-method dispatch — earlier `setAnrHandler` overwrote the
  // single channel handler; with `onUiHangDetected` (and future
  // bridges) sharing the same channel we route to per-method
  // listeners instead.
  static final Map<String, void Function(dynamic)> _listeners = {};
  static bool _routerInstalled = false;

  static void _ensureRouter() {
    if (_routerInstalled) return;
    _routerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      final h = _listeners[call.method];
      if (h == null) return;
      try {
        h(call.arguments);
      } catch (_) {
        // Listener errors must never propagate back across the
        // method channel — Flutter would log them as unhandled.
      }
    });
  }

  static Future<void> startAnrDetection({required int thresholdMs}) async {
    await _channel.invokeMethod('startAnrDetection', {
      'thresholdMs': thresholdMs,
    });
  }

  static Future<void> stopAnrDetection() async {
    await _channel.invokeMethod('stopAnrDetection');
  }

  /// iOS only — start the UI-hang detector (separate from ANR).
  /// Fires `onUiHangDetected` every time the main thread blocks for
  /// at least `thresholdMs`. No-op on Android (Choreographer-based
  /// detection runs there instead).
  static Future<void> startUiHangDetection({required int thresholdMs}) async {
    try {
      await _channel.invokeMethod('startUiHangDetection', {
        'thresholdMs': thresholdMs,
      });
    } catch (_) {
      // MethodNotImplemented on Android — expected, ignore.
    }
  }

  static Future<void> stopUiHangDetection() async {
    try {
      await _channel.invokeMethod('stopUiHangDetection');
    } catch (_) {
      // ignore
    }
  }

  /// Simulate an ANR by blocking the native main thread.
  /// Only for testing — triggers the ANR watchdog.
  static Future<void> simulateAnr({int durationMs = 6000}) async {
    await _channel.invokeMethod('simulateAnr', {'durationMs': durationMs});
  }

  /// Simulate a real native crash so KSCrash (iOS) / the NDK signal
  /// handler (Android) actually fires and writes a report to disk.
  /// On next launch, `getNativeCrashReports` returns it. Only for
  /// testing — calling this will terminate the app.
  static Future<void> simulateCrash() async {
    try {
      await _channel.invokeMethod('simulateCrash');
    } catch (_) {
      // Process is about to die — exception is irrelevant.
    }
  }

  static Future<String> getTimezone() async {
    try {
      final result = await _channel.invokeMethod<String>('getTimezone');
      return result ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> getOsBuild() async {
    try {
      final result = await _channel.invokeMethod<String>('getOsBuild');
      return result ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> getCpuArch() async {
    try {
      final result = await _channel.invokeMethod<String>('getCpuArch');
      return result ?? '';
    } catch (_) {
      return '';
    }
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

  /// iOS only — drain MetricKit crash + hang diagnostic payloads that
  /// the OS delivered asynchronously since the last call. Returns an
  /// empty list on Android.
  static Future<List<Map<String, dynamic>>> getMetricKitReports() async {
    try {
      final result = await _channel.invokeListMethod<Map>(
        'getMetricKitReports',
      );
      if (result == null) return [];
      return result.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (_) {
      // Method not implemented on Android — that's expected.
      return [];
    }
  }

  /// Android only — drain `ApplicationExitInfo` records (API 30+).
  /// Captures ANRs, OOM kills, native crashes, JVM crashes the OS knew
  /// about even when the in-process handlers couldn't write to disk.
  /// Returns an empty list on iOS and on Android API < 30.
  static Future<List<Map<String, dynamic>>> getExitInfoReports() async {
    try {
      final result = await _channel.invokeListMethod<Map>('getExitInfoReports');
      if (result == null) return [];
      return result.map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (_) {
      // Method not implemented on iOS — that's expected.
      return [];
    }
  }

  /// Set up handler for ANR events from native side.
  static void setAnrHandler(void Function(int durationMs) onAnr) {
    _ensureRouter();
    _listeners['onAnrDetected'] = (args) {
      if (args is int) onAnr(args);
    };
  }

  /// Push the latest breadcrumb buffer to the native side so each native
  /// crash report carries the breadcrumbs current at crash time. On iOS
  /// this lands in `KSCrash.userInfo` and rides into the crash report.
  /// On Android the call is a no-op — the on-disk file (kept across
  /// launches by [CrashDetector]) is the authoritative source there.
  static Future<void> setBreadcrumbs(String json) async {
    try {
      await _channel.invokeMethod('setBreadcrumbs', {'json': json});
    } catch (_) {
      // MissingPluginException on platforms without an impl — expected.
    }
  }

  /// iOS only — handler for sub-ANR UI hangs (≥ `iosHangThresholdMs`).
  static void setUiHangHandler(void Function(int durationMs) onHang) {
    _ensureRouter();
    _listeners['onUiHangDetected'] = (args) {
      if (args is int) onHang(args);
    };
  }
}
