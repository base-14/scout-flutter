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

  /// Whether to track app startup time (cold and warm start).
  final bool enableStartupTracking;

  /// Whether to track network connectivity type as a resource attribute.
  final bool enableConnectivityTracking;

  /// OTLP headers sent with every export request (traces and metrics).
  /// Use this for authentication tokens, API keys, etc.
  final Map<String, String>? headers;

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
    this.enableStartupTracking = true,
    this.enableConnectivityTracking = true,
    this.headers,
  }) : longTaskThresholdMs = longTaskThresholdMs < 20 ? 20 : longTaskThresholdMs,
       anrThresholdMs = anrThresholdMs < 1000 ? 1000 : anrThresholdMs;
}
