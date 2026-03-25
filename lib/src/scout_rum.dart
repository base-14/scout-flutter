import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';

import 'auto_name_navigator_observer.dart';
import 'scout_rum_config.dart';
import 'breadcrumb_manager.dart';
import 'global_tap_detector.dart';

/// Main entry point for Scout Flutter RUM.
///
/// Call [initialize] in your `main()` before `runApp()`.
/// That's it — taps, lifecycle, and errors are tracked automatically.
///
/// For navigation tracking, add [navigatorObserver] to your app:
/// ```dart
/// MaterialApp(
///   navigatorObservers: [ScoutFlutter.navigatorObserver],
/// )
/// ```
class ScoutFlutter {
  ScoutFlutter._();

  static ScoutFlutterConfig? _config;
  static final BreadcrumbManager _breadcrumbManager = BreadcrumbManager();
  static String? _userId;
  static String? _userEmail;
  static GlobalTapDetector? _tapDetector;
  static AppLifecycleListener? _lifecycleListener;
  static AutoNameNavigatorObserver? _navObserver;

  /// Current config, or null if not initialized.
  static ScoutFlutterConfig? get config => _config;

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _config != null;

  /// Access the breadcrumb manager.
  static BreadcrumbManager get breadcrumbManager => _breadcrumbManager;

  /// Navigator observer for automatic screen tracking.
  /// Add this to your MaterialApp/CupertinoApp's navigatorObservers.
  static NavigatorObserver get navigatorObserver {
    _navObserver ??= AutoNameNavigatorObserver(
      onScreenChanged: (screenName) {
        if (!isInitialized) return;
        final span = FlutterOTel.tracer.startSpan(
          'screen_view',
          attributes: <String, Object>{
            'screen.name': screenName,
            if (_userId != null) 'enduser.id': _userId!,
            if (_userEmail != null) 'enduser.email': _userEmail!,
          }.toAttributes(),
        );
        addBreadcrumb('navigation', 'screen: $screenName');
        span.end();
      },
    );
    return _navObserver!;
  }

  /// Initialize Scout Flutter RUM. Call this in `main()` before `runApp()`.
  ///
  /// This automatically sets up:
  /// - Tap detection (via global pointer route)
  /// - Lifecycle tracking
  /// - Error tracking
  ///
  /// For navigation tracking, add [navigatorObserver] to your app's
  /// navigatorObservers list.
  static Future<void> initialize({required ScoutFlutterConfig config}) async {
    WidgetsFlutterBinding.ensureInitialized();

    final resourceAttrs = <String, Object>{
      if (config.environment != null)
        'deployment.environment': config.environment!,
      ...?config.resourceAttributes,
      ...await _collectDeviceAttributes(),
    };

    await FlutterOTel.initialize(
      serviceName: config.serviceName,
      serviceVersion: config.serviceVersion,
      tracerName: config.serviceName,
      endpoint: config.endpoint,
      secure: config.secure,
      enableMetrics: false,
      resourceAttributes:
          resourceAttrs.isEmpty ? null : resourceAttrs.toAttributes(),
    );

    _config = config;

    if (config.enableErrorTracking) {
      _setupErrorHandlers();
    }

    if (config.enableAutoTapTracking) {
      _setupGlobalTapDetection(config);
    }

    if (config.enableLifecycleTracking) {
      _setupLifecycleTracking();
    }
  }

  static void _setupGlobalTapDetection(ScoutFlutterConfig config) {
    _tapDetector = GlobalTapDetector(
      customGestureDetector: config.customGestureDetector,
      onTapDetected: (elementName, elementDescription) {
        if (!isInitialized) return;
        final span = FlutterOTel.tracer.startSpan(
          'tap',
          attributes: <String, Object>{
            'target.type': elementName,
            'target.label': elementDescription,
            if (_userId != null) 'enduser.id': _userId!,
            if (_userEmail != null) 'enduser.email': _userEmail!,
          }.toAttributes(),
        );
        addBreadcrumb('tap', '$elementName: $elementDescription');
        span.end();
      },
    );
    _tapDetector!.start();
  }

  static void _setupLifecycleTracking() {
    _lifecycleListener = AppLifecycleListener(
      onPause: () {
        addBreadcrumb('lifecycle', 'app_paused');
      },
      onResume: () {
        addBreadcrumb('lifecycle', 'app_resumed');
      },
      onExitRequested: () async {
        addBreadcrumb('lifecycle', 'app_exit_requested');
        return AppExitResponse.exit;
      },
    );
  }

  static Future<Map<String, Object>> _collectDeviceAttributes() async {
    final attrs = <String, Object>{};

    try {
      final battery = Battery();
      final level = await battery.batteryLevel;
      final state = await battery.batteryState;
      attrs['device.battery.level'] = level;
      attrs['device.battery.state'] = state.name;
    } catch (_) {
      // Battery info unavailable (e.g. desktop)
    }

    try {
      final deviceInfo = DeviceInfoPlugin();
      final info = await deviceInfo.deviceInfo;
      final data = info.data;
      if (data['model'] != null) attrs['device.model'] = data['model'].toString();
      if (data['manufacturer'] != null) attrs['device.manufacturer'] = data['manufacturer'].toString();
      if (data['brand'] != null) attrs['device.brand'] = data['brand'].toString();
      if (data['isPhysicalDevice'] != null) attrs['device.is_physical'] = data['isPhysicalDevice'].toString();
    } catch (_) {
      // Device info unavailable
    }

    return attrs;
  }

  static void _setupErrorHandlers() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _breadcrumbManager.record(
        'error',
        'flutter_error: ${details.exceptionAsString()}',
      );
      FlutterOTel.reportError(
        details.exceptionAsString(),
        details.exception,
        details.stack,
        attributes: {
          'breadcrumbs': _breadcrumbManager.toJsonString(),
        },
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _breadcrumbManager.record(
        'error',
        'uncaught_error: ${error.runtimeType}',
      );
      FlutterOTel.reportError(
        'Uncaught error',
        error,
        stack,
        attributes: {
          'breadcrumbs': _breadcrumbManager.toJsonString(),
        },
      );
      return true;
    };
  }

  /// Record a breadcrumb for error context.
  static void addBreadcrumb(String type, String message) {
    _breadcrumbManager.record(type, message);
  }

  /// Report an error manually.
  static void reportError(Object error, StackTrace? stackTrace) {
    _breadcrumbManager.record('error', 'manual_error: ${error.runtimeType}');
    FlutterOTel.reportError(
      error.toString(),
      error,
      stackTrace,
      attributes: {
        'breadcrumbs': _breadcrumbManager.toJsonString(),
      },
    );
  }

  /// Set user identity. Attached to subsequent spans.
  static void setUser({required String id, String? email}) {
    _userId = id;
    _userEmail = email;
  }

  /// Clear user identity.
  static void clearUser() {
    _userId = null;
    _userEmail = null;
  }

  /// Current user ID, if set.
  static String? get userId => _userId;

  /// Current user email, if set.
  static String? get userEmail => _userEmail;

  /// Access the OTel tracer for custom spans.
  static dynamic get tracer => FlutterOTel.tracer;

  /// Log a custom business event as a span.
  static void logEvent(String name, {Map<String, dynamic>? attributes}) {
    final attrMap = <String, Object>{
      if (_userId != null) 'enduser.id': _userId!,
      if (_userEmail != null) 'enduser.email': _userEmail!,
      ...?attributes,
    };
    final span = FlutterOTel.tracer.startSpan(
      name,
      attributes: attrMap.isEmpty ? null : attrMap.toAttributes(),
    );
    span.end();
  }

  /// Reset all state for test isolation.
  @visibleForTesting
  static void resetForTesting() {
    _config = null;
    _breadcrumbManager.clear();
    _userId = null;
    _userEmail = null;
    _tapDetector = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _navObserver = null;
  }
}
