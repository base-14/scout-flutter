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
typedef CustomGestureElementDetector = GestureDetectorInfo? Function(Widget widget);

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
  });
}
