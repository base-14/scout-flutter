import 'package:flutter/widgets.dart';

/// Info about a detected gesture element, used for custom widget detection.
@immutable
class GestureDetectorInfo {
  final String elementName;
  final bool searchForBetter;
  final bool searchForText;

  const GestureDetectorInfo(
    this.elementName, {
    this.searchForBetter = false,
    this.searchForText = true,
  });
}

/// Callback type for custom gesture detection.
typedef CustomGestureElementDetector =
    GestureDetectorInfo? Function(Widget widget);

/// Callback to filter/modify events before export.
/// Return the event map to send, or null to drop it.
/// The map includes a 'type' field: "span", "metric", or "log".
typedef BeforeSendCallback =
    Map<String, dynamic>? Function(Map<String, dynamic> event);

/// Configuration for Scout Flutter RUM.
@immutable
class ScoutFlutterConfig {
  final String serviceName;
  final String endpoint;
  final String serviceVersion;
  final String? environment;
  final Map<String, String>? resourceAttributes;
  final bool enableAutoTapTracking;
  final bool enableErrorTracking;
  final bool enableLifecycleTracking;
  final bool secure;
  final CustomGestureElementDetector? customGestureDetector;

  /// Whether to detect long tasks (jank) on the main isolate.
  final bool enableLongTaskDetection;

  /// Threshold in milliseconds for a task to be considered "long".
  /// Values below 20 are clamped to 20.
  final int longTaskThresholdMs;

  /// Whether to collect performance metrics (FPS, memory, CPU, frame times).
  final bool enablePerformanceMetrics;

  /// Whether to detect Application Not Responding (ANR) events.
  final bool enableAnrDetection;

  /// Threshold in milliseconds for an ANR event.
  /// Values below 1000 are clamped to 1000.
  final int anrThresholdMs;

  /// iOS only — threshold in milliseconds for sub-ANR UI hangs detected
  /// by a continuous CFRunLoop watchdog. Fires `ui_hang` spans for any
  /// main-thread block longer than this, complementing the slower ANR
  /// detector and KSCrash's mainThreadDeadlock monitor (which only
  /// fires at 5 s+).
  ///
  /// Default 250 (Apple's hang-detector baseline). Min 50 (anything
  /// lower is noise — animation frames take ~16 ms). Set to 0 to
  /// disable while keeping ANR detection on.
  final int iosHangThresholdMs;

  /// Whether to track app startup time (cold and warm start).
  final bool enableStartupTracking;

  /// Whether to track network connectivity type as a resource attribute.
  final bool enableConnectivityTracking;

  /// OTLP headers sent with every export request (traces and metrics).
  /// Use this for authentication tokens, API keys, etc.
  final Map<String, String>? headers;

  /// Whether to auto-track HTTP requests via HttpOverrides.
  final bool enableNetworkTracking;

  /// URL patterns to exclude from network tracking.
  final List<RegExp>? ignoreUrlPatterns;

  /// Hosts that receive W3C traceparent headers for distributed tracing.
  final List<String>? firstPartyHosts;

  /// Percentage of sessions to sample (0.0-100.0). Default 1.0 (1% of
  /// sessions). Errors bypass this gate by default — see
  /// [alwaysCaptureErrors].
  final double sessionSampleRate;

  /// When true (default), error- and crash-class spans (`error`,
  /// `native_crash`, `app_crash`, `anr`) bypass [sessionSampleRate] and
  /// are always exported regardless of the per-session sampling decision.
  /// Set to false to subject errors to the same sampling as other
  /// telemetry.
  final bool alwaysCaptureErrors;

  /// Minutes of inactivity before rotating the session. Default 30.
  final int sessionTimeoutMinutes;

  /// Maximum session lifetime in minutes. The session rotates the next time
  /// its ID is read after this many minutes have elapsed since the session
  /// started, regardless of activity. Default 60. Set to 0 to disable.
  final int maxSessionDurationMinutes;

  /// Whether to enable structured log export via OTLP.
  final bool enableLogging;

  /// Whether to capture print()/debugPrint() as info-level logs.
  final bool capturePrintStatements;

  /// Max offline storage in MB for failed exports. Default 5.
  final int maxOfflineStorageMb;

  /// Disable on-disk offline buffering — strict at-most-once delivery.
  /// Default true. When false, retry-exhausted batches are dropped
  /// instead of being persisted for the next launch's replay.
  final bool offlineBufferEnabled;

  /// Per-signal item caps. Oldest batches FIFO-evicted first when a
  /// cap is exceeded. Defaults: traces 5000, metrics 2000, logs 5000.
  /// Use these for predictable storage budgets — the `maxOfflineStorageMb`
  /// cap is a coarse safety net that runs in addition.
  final int offlineMaxTraceItems;
  final int offlineMaxMetricItems;
  final int offlineMaxLogItems;

  /// Callback to filter/modify events before export.
  final BeforeSendCallback? beforeSend;

  /// Emit verbose per-event diagnostics via `debugPrint` while the SDK
  /// is running. Off by default. When enabled, every init, session
  /// rotation, sampling decision, export batch, and log entry prints
  /// one line prefixed `[Scout]`. Intended for local development —
  /// noisy in production.
  final bool debugLogging;

  const ScoutFlutterConfig({
    required this.serviceName,
    required this.endpoint,
    this.serviceVersion = '1.0.0',
    this.environment,
    this.resourceAttributes,
    this.enableAutoTapTracking = true,
    this.enableErrorTracking = true,
    this.enableLifecycleTracking = true,
    this.secure = true,
    this.customGestureDetector,
    this.enablePerformanceMetrics = true,
    this.enableLongTaskDetection = true,
    int longTaskThresholdMs = 100,
    this.enableAnrDetection = true,
    int anrThresholdMs = 5000,
    int iosHangThresholdMs = 250,
    this.enableStartupTracking = true,
    this.enableConnectivityTracking = true,
    this.headers,
    this.enableNetworkTracking = true,
    this.ignoreUrlPatterns,
    this.firstPartyHosts,
    double sessionSampleRate = 1.0,
    this.alwaysCaptureErrors = true,
    this.sessionTimeoutMinutes = 30,
    int maxSessionDurationMinutes = 60,
    this.enableLogging = true,
    this.capturePrintStatements = false,
    this.maxOfflineStorageMb = 5,
    this.offlineBufferEnabled = true,
    this.offlineMaxTraceItems = 5000,
    this.offlineMaxMetricItems = 2000,
    this.offlineMaxLogItems = 5000,
    this.beforeSend,
    this.debugLogging = false,
  }) : longTaskThresholdMs =
           longTaskThresholdMs < 20 ? 20 : longTaskThresholdMs,
       anrThresholdMs = anrThresholdMs < 1000 ? 1000 : anrThresholdMs,
       iosHangThresholdMs =
           iosHangThresholdMs <= 0
               ? 0
               : (iosHangThresholdMs < 50 ? 50 : iosHangThresholdMs),
       sessionSampleRate =
           sessionSampleRate < 0.0
               ? 0.0
               : (sessionSampleRate > 100.0 ? 100.0 : sessionSampleRate),
       maxSessionDurationMinutes =
           maxSessionDurationMinutes < 0 ? 0 : maxSessionDurationMinutes;
}
