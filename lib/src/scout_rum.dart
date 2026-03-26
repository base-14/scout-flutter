import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show OtlpHttpSpanExporter, OtlpHttpExporterConfig, SimpleSpanProcessor;
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';
import 'package:path_provider/path_provider.dart';

import 'auto_name_navigator_observer.dart';
import 'fixed_http_metric_exporter.dart';
import 'fixed_http_log_exporter.dart';
import 'frame_metrics_collector.dart';
import 'long_task_detector.dart';
import 'native_vitals_collector.dart';
import 'offline_queue.dart';
import 'scout_dio_interceptor.dart';
import 'scout_http_overrides.dart';
import 'scout_logger.dart' as scout_log;
import 'scout_platform_channel.dart';
import 'scout_rum_config.dart';
import 'session_manager.dart';
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
  static LongTaskDetector? _longTaskDetector;
  static AppLifecycleListener? _lifecycleListener;
  static AutoNameNavigatorObserver? _navObserver;
  static FrameMetricsCollector? _frameMetricsCollector;
  static NativeVitalsCollector? _nativeVitalsCollector;
  static Stopwatch? _coldStartStopwatch;
  static bool _coldStartRecorded = false;
  static Stopwatch? _warmStartStopwatch;
  static String _connectivityType = 'unknown';
  static dynamic _meter;
  static SessionManager? _sessionManager;
  static scout_log.ScoutLogger? _logger;
  static FixedHttpLogExporter? _logExporter;
  static OfflineQueue? _offlineQueue;
  static Timer? _offlineFlushTimer;
  static ScoutDioInterceptor? _dioInterceptor;
  static DebugPrintCallback? _originalDebugPrint;

  /// Current config, or null if not initialized.
  static ScoutFlutterConfig? get config => _config;

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _config != null;

  /// Access the breadcrumb manager.
  static BreadcrumbManager get breadcrumbManager => _breadcrumbManager;

  /// Current session ID.
  static String? get sessionId => _sessionManager?.sessionId;

  /// Dio interceptor for custom Dio adapter users.
  static ScoutDioInterceptor get dioInterceptor {
    _dioInterceptor ??= ScoutDioInterceptor(
      firstPartyHosts: _config?.firstPartyHosts,
      onRequestCompleted: _onHttpRequestCompleted,
    );
    return _dioInterceptor!;
  }

  /// Navigator observer for automatic screen tracking.
  /// Add this to your MaterialApp/CupertinoApp's navigatorObservers.
  static NavigatorObserver get navigatorObserver {
    _navObserver ??= AutoNameNavigatorObserver(
      onScreenChanged: (screenName) {
        _emitSpan('screen_view', {
          'screen.name': screenName,
          ..._commonAttributes(),
        });
        addBreadcrumb('navigation', 'screen: $screenName');
      },
      onScreenLoadTime: (screenName, loadTime) {
        _emitSpan('screen_load', {
          'screen.name': screenName,
          'screen.load_time': loadTime.inMilliseconds / 1000.0,
          ..._commonAttributes(),
        });
      },
      onScreenEnter: (screenName) {
        if (!isInitialized) return;
        addBreadcrumb('view_session', 'entered: $screenName');
      },
      onScreenExit: (screenName, timeSpent) {
        _emitSpan('view_session', {
          'screen.name': screenName,
          'view.time_spent': timeSpent.inMilliseconds / 1000.0,
          ..._commonAttributes(),
        });
        addBreadcrumb(
          'view_session',
          'exited: $screenName (${timeSpent.inMilliseconds}ms)',
        );
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
    _coldStartStopwatch ??= Stopwatch()..start();
    WidgetsFlutterBinding.ensureInitialized();

    final resourceAttrs = <String, Object>{
      if (config.environment != null)
        'environment': config.environment!,
      ...?config.resourceAttributes,
      ...await _collectDeviceAttributes(),
    };

    // Build the HTTP endpoint for export (both traces and metrics).
    String httpEndpoint = config.endpoint;
    if (!httpEndpoint.startsWith('http://') &&
        !httpEndpoint.startsWith('https://')) {
      httpEndpoint =
          config.secure ? 'https://$httpEndpoint' : 'http://$httpEndpoint';
    }

    // Force HTTP for spans (FlutterOTel defaults to gRPC on mobile).
    final spanExporter = OtlpHttpSpanExporter(
      OtlpHttpExporterConfig(
        endpoint: httpEndpoint,
        headers: config.headers,
      ),
    );

    await FlutterOTel.initialize(
      serviceName: config.serviceName,
      serviceVersion: config.serviceVersion,
      tracerName: config.serviceName,
      endpoint: httpEndpoint,
      secure: config.secure,
      enableMetrics: config.enablePerformanceMetrics,
      spanProcessor: SimpleSpanProcessor(spanExporter),
      // Use our fixed exporter to work around the frozen protobuf bug
      // in dartastic_opentelemetry's OtlpHttpMetricExporter.
      // See: https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/1
      metricExporter: config.enablePerformanceMetrics
          ? FixedHttpMetricExporter(
              endpoint: httpEndpoint,
              headers: config.headers,
            )
          : null,
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

    if (config.enableLongTaskDetection) {
      _setupLongTaskDetection(config);
    }

    if (config.enableAnrDetection) {
      _setupAnrDetection(config);
    }

    if (config.enablePerformanceMetrics) {
      _meter = FlutterOTel.meter(name: config.serviceName);
      _setupFrameMetrics();
      _setupNativeVitals();
    }

    if (config.enableStartupTracking) {
      _measureColdStart();
    }

    if (config.enableConnectivityTracking) {
      Connectivity().onConnectivityChanged.listen((result) {
        if (result.isNotEmpty) {
          _connectivityType = result.first.name;
        }
        _flushOfflineQueue();
      });
    }

    // --- Phase 3: Session, Logging, Network, Offline ---

    // Session manager
    _sessionManager = SessionManager(
      sampleRate: config.sessionSampleRate,
      timeoutMinutes: config.sessionTimeoutMinutes,
    );

    // Offline queue
    final tempDir = await getTemporaryDirectory();
    final offlineDir = Directory('${tempDir.path}/scout_offline');
    _offlineQueue = OfflineQueue(
      directory: offlineDir,
      maxStorageMb: config.maxOfflineStorageMb,
    );

    // Periodic offline flush (every 60 seconds)
    _offlineFlushTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _flushOfflineQueue(),
    );

    // Structured logging
    if (config.enableLogging) {
      _logExporter = FixedHttpLogExporter(
        endpoint: httpEndpoint,
        headers: config.headers,
      );
      _logger = scout_log.ScoutLogger(onLog: _onLogEntry);

      // Capture debugPrint() as info-level logs
      if (config.capturePrintStatements) {
        _originalDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          _originalDebugPrint!(message, wrapWidth: wrapWidth);
          if (message != null) {
            _logger?.logInfo(message);
          }
        };
      }
    }

    // HTTP tracking via HttpOverrides
    if (config.enableNetworkTracking) {
      final existingOverrides = HttpOverrides.current;
      HttpOverrides.global = ScoutHttpOverrides(
        existingOverrides: existingOverrides,
        exportEndpoint: httpEndpoint,
        ignorePatterns: config.ignoreUrlPatterns,
        firstPartyHosts: config.firstPartyHosts,
        onRequestCompleted: _onHttpRequestCompleted,
      );
    }
  }

  /// Creates and immediately ends a span, subject to sampling and beforeSend.
  static void _emitSpan(String name, Map<String, Object> attributes) {
    if (!isInitialized) return;
    if (!(_sessionManager?.isSampled ?? true)) return;

    if (_config?.beforeSend != null) {
      final event = <String, dynamic>{
        'type': 'span',
        'name': name,
        ...attributes,
      };
      final result = _config!.beforeSend!(event);
      if (result == null) return;
      attributes = {};
      for (final entry in result.entries) {
        if (entry.key != 'type' && entry.key != 'name' && entry.value != null) {
          attributes[entry.key] = entry.value as Object;
        }
      }
    }

    final span = FlutterOTel.tracer.startSpan(
      name,
      attributes: attributes.isEmpty ? null : attributes.toAttributes(),
    );
    span.end();
  }

  static void _setupGlobalTapDetection(ScoutFlutterConfig config) {
    _tapDetector = GlobalTapDetector(
      customGestureDetector: config.customGestureDetector,
      onTapDetected: (elementName, elementDescription) {
        _emitSpan('user_interaction', {
          'user_interaction.type': 'click',
          'user_interaction.target': elementDescription,
          'user_interaction.target.type': elementName,
          ..._commonAttributes(),
        });
        addBreadcrumb('tap', '$elementName: $elementDescription');
      },
    );
    _tapDetector!.start();
  }

  static void _setupLifecycleTracking() {
    _lifecycleListener = AppLifecycleListener(
      onInactive: () {
        if (_config?.enableStartupTracking == true) {
          _warmStartStopwatch = Stopwatch()..start();
        }
      },
      onPause: () {
        _sessionManager?.onBackground();
        addBreadcrumb('lifecycle', 'app_paused');
      },
      onResume: () {
        _sessionManager?.onForeground();
        addBreadcrumb('lifecycle', 'app_resumed');
        if (_config?.enableStartupTracking == true) {
          _measureWarmStart();
        }
      },
      onExitRequested: () async {
        addBreadcrumb('lifecycle', 'app_exit_requested');
        return AppExitResponse.exit;
      },
    );
  }

  static void _measureColdStart() {
    if (_coldStartRecorded || _coldStartStopwatch == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_coldStartRecorded) return;
      _coldStartRecorded = true;
      final duration = _coldStartStopwatch!.elapsed;
      _coldStartStopwatch!.stop();
      _emitSpan('app_startup', {
        'app_startup.type': 'cold',
        'app_startup.duration': duration.inMilliseconds / 1000.0,
        ..._commonAttributes(),
      });
      addBreadcrumb('startup', 'cold_start: ${duration.inMilliseconds}ms');
    });
  }

  static void _measureWarmStart() {
    if (_warmStartStopwatch == null) return;
    final stopwatch = _warmStartStopwatch!;
    _warmStartStopwatch = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final duration = stopwatch.elapsed;
      stopwatch.stop();
      _emitSpan('app_startup', {
        'app_startup.type': 'warm',
        'app_startup.duration': duration.inMilliseconds / 1000.0,
        ..._commonAttributes(),
      });
      addBreadcrumb('startup', 'warm_start: ${duration.inMilliseconds}ms');
    });
  }

  static void _setupLongTaskDetection(ScoutFlutterConfig config) {
    _longTaskDetector = LongTaskDetector(
      threshold: Duration(milliseconds: config.longTaskThresholdMs),
      onLongTask: (duration) {
        String? currentScreen;
        if (_navObserver != null) {
          currentScreen = _navObserver!.currentScreenName;
        }
        _emitSpan('long_task', {
          'long_task.duration': duration.inMilliseconds / 1000.0,
          'long_task.threshold': config.longTaskThresholdMs / 1000.0,
          if (currentScreen != null) 'screen.name': currentScreen,
          ..._commonAttributes(),
        });
        addBreadcrumb('long_task', 'Long task: ${duration.inMilliseconds}ms');
      },
    );
    _longTaskDetector!.start();
  }

  static Future<void> _setupAnrDetection(ScoutFlutterConfig config) async {
    ScoutPlatformChannel.setAnrHandler((durationMs) {
      String? currentScreen;
      if (_navObserver != null) {
        currentScreen = _navObserver!.currentScreenName;
      }
      _emitSpan('anr', {
        'anr.duration': durationMs / 1000.0,
        'anr.threshold': config.anrThresholdMs / 1000.0,
        if (currentScreen != null) 'screen.name': currentScreen,
        ..._commonAttributes(),
      });
      addBreadcrumb('anr', 'App not responding: ${durationMs}ms');
    });
    await ScoutPlatformChannel.startAnrDetection(
      thresholdMs: config.anrThresholdMs,
    );
  }

  static void _setupFrameMetrics() {
    final meter = _meter;

    final buildHistogram = meter.createHistogram<double>(
      name: 'flutter.frame.build_time',
      description: 'Flutter widget build duration',
      unit: 's',
    );

    final rasterHistogram = meter.createHistogram<double>(
      name: 'flutter.frame.raster_time',
      description: 'Flutter GPU raster duration',
      unit: 's',
    );

    _frameMetricsCollector = FrameMetricsCollector(
      onFrameTiming: (buildTime, rasterTime) {
        if (!(_sessionManager?.isSampled ?? true)) return;
        final screenAttr = <String, Object>{
          if (_navObserver?.currentScreenName != null)
            'screen.name': _navObserver!.currentScreenName!,
          if (_sessionManager != null)
            'session.id': _sessionManager!.sessionId,
        }.toAttributes();

        buildHistogram.record(
          buildTime.inMicroseconds / 1000000.0,
          screenAttr,
        );
        rasterHistogram.record(
          rasterTime.inMicroseconds / 1000000.0,
          screenAttr,
        );
      },
      onFrozenFrame: (duration) {
        String? currentScreen;
        if (_navObserver != null) {
          currentScreen = _navObserver!.currentScreenName;
        }
        _emitSpan('frozen_frame', {
          'frozen_frame.duration': duration.inMilliseconds / 1000.0,
          if (currentScreen != null) 'screen.name': currentScreen,
          ..._commonAttributes(),
        });
        addBreadcrumb(
          'frozen_frame',
          'Frozen frame: ${duration.inMilliseconds}ms',
        );
      },
    );
    _frameMetricsCollector!.start();
  }

  static void _setupNativeVitals() {
    // Get the SDK Meter directly, bypassing UIMeter which has a broken
    // createGauge cast (UIMeter casts APIGauge as Gauge, which fails).
    final sdkMeter = FlutterOTel.meterProvider.delegate.getMeter(
      name: _config!.serviceName,
    );

    final memoryGauge = sdkMeter.createGauge<double>(
      name: 'flutter.memory.usage',
      description: 'App memory usage',
      unit: 'By',
    );

    final cpuGauge = sdkMeter.createGauge<double>(
      name: 'flutter.cpu.usage',
      description: 'App CPU usage percentage',
      unit: '%',
    );

    _nativeVitalsCollector = NativeVitalsCollector(
      onMemory: (usedBytes, maxBytes) {
        if (!(_sessionManager?.isSampled ?? true)) return;
        final attrs = <String, Object>{
          if (_navObserver?.currentScreenName != null)
            'screen.name': _navObserver!.currentScreenName!,
          if (_sessionManager != null)
            'session.id': _sessionManager!.sessionId,
        }.toAttributes();
        memoryGauge.record(usedBytes.toDouble(), attrs);
      },
      onCpu: (cpuPercent) {
        if (!(_sessionManager?.isSampled ?? true)) return;
        final attrs = <String, Object>{
          if (_navObserver?.currentScreenName != null)
            'screen.name': _navObserver!.currentScreenName!,
          if (_sessionManager != null)
            'session.id': _sessionManager!.sessionId,
        }.toAttributes();
        cpuGauge.record(cpuPercent, attrs);
      },
    );
    _nativeVitalsCollector!.start();
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
      if (data['model'] != null) {
        attrs['device.model.name'] = data['model'].toString();
      }
      if (data['manufacturer'] != null) {
        attrs['device.manufacturer'] = data['manufacturer'].toString();
      }
      if (data['brand'] != null) {
        attrs['device.brand'] = data['brand'].toString();
      }
      if (data['isPhysicalDevice'] != null) {
        attrs['device.is_physical'] = data['isPhysicalDevice'].toString();
      }
    } catch (_) {
      // Device info unavailable
    }

    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.isNotEmpty) {
        _connectivityType = connectivity.first.name;
        attrs['network.connection.type'] = _connectivityType;
      }
    } catch (_) {}

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
        attributes: {'breadcrumbs': _breadcrumbManager.toJsonString()},
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
        attributes: {'breadcrumbs': _breadcrumbManager.toJsonString()},
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
      attributes: {'breadcrumbs': _breadcrumbManager.toJsonString()},
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

  static Map<String, Object> _commonAttributes() {
    return {
      if (_userId != null) 'enduser.id': _userId!,
      if (_userEmail != null) 'enduser.email': _userEmail!,
      if (_connectivityType != 'unknown')
        'network.connection.type': _connectivityType,
      if (_sessionManager != null) 'session.id': _sessionManager!.sessionId,
    };
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
      ..._commonAttributes(),
      ...?attributes,
    };
    _emitSpan(name, attrMap);
  }

  /// Log a structured message.
  static void log(scout_log.LogLevel level, String message,
      {Map<String, Object>? attributes}) {
    _logger?.log(level, message, attributes: attributes);
  }

  static void logDebug(String message, {Map<String, Object>? attributes}) =>
      log(scout_log.LogLevel.debug, message, attributes: attributes);

  static void logInfo(String message, {Map<String, Object>? attributes}) =>
      log(scout_log.LogLevel.info, message, attributes: attributes);

  static void logWarning(String message, {Map<String, Object>? attributes}) =>
      log(scout_log.LogLevel.warning, message, attributes: attributes);

  static void logError(String message, {Map<String, Object>? attributes}) =>
      log(scout_log.LogLevel.error, message, attributes: attributes);

  static void _onHttpRequestCompleted(HttpRequestData data) {
    if (!isInitialized) return;
    if (!(_sessionManager?.isSampled ?? true)) return;

    var attributes = <String, Object>{
      'http.method': data.method,
      'http.url': data.url.toString(),
      'http.status_code': data.statusCode,
      'http.response_content_length': data.responseSize,
      'http.duration_ms': data.durationMs,
      if (data.error != null) 'http.error': data.error!,
      ..._commonAttributes(),
    };

    if (_config?.beforeSend != null) {
      final event = <String, dynamic>{
        'type': 'span',
        'name': 'http.request',
        ...attributes,
      };
      final result = _config!.beforeSend!(event);
      if (result == null) return;
      attributes = {};
      for (final entry in result.entries) {
        if (entry.key != 'type' &&
            entry.key != 'name' &&
            entry.value != null) {
          attributes[entry.key] = entry.value as Object;
        }
      }
    }

    final span = FlutterOTel.tracer.startSpan(
      'http.request',
      attributes: attributes.isEmpty ? null : attributes.toAttributes(),
    );
    if (data.error != null) {
      span.setStatus(SpanStatusCode.Error, data.error!);
    }
    span.end();
  }

  static void _onLogEntry(scout_log.ScoutLogEntry entry) {
    if (!(_sessionManager?.isSampled ?? true)) return;

    if (_config?.beforeSend != null) {
      final event = <String, dynamic>{
        'type': 'log',
        'severity': entry.level.severityText,
        'message': entry.message,
        ...?entry.attributes,
      };
      final result = _config!.beforeSend!(event);
      if (result == null) return;
    }

    final logRecord = ScoutLogRecord(
      severityNumber: entry.level.severityNumber,
      severityText: entry.level.severityText,
      body: entry.message,
      timestampNanos: BigInt.from(entry.timestamp.microsecondsSinceEpoch) *
          BigInt.from(1000),
      attributes: {
        'session.id': _sessionManager?.sessionId ?? '',
        if (_navObserver?.currentScreenName != null)
          'screen.name': _navObserver!.currentScreenName!,
        if (_userId != null) 'enduser.id': _userId!,
        ...?entry.attributes,
      },
    );
    _logExporter?.export([logRecord]).then((success) {
      if (!success) {
        _offlineQueue?.enqueue('logs', [
          {
            'severity_number': logRecord.severityNumber,
            'severity_text': logRecord.severityText,
            'body': logRecord.body,
            'timestamp_nanos': logRecord.timestampNanos.toString(),
            ...?logRecord.attributes,
          },
        ]);
      }
    });
  }

  static Future<void> _flushOfflineQueue() async {
    if (_offlineQueue == null) return;
    final batches = await _offlineQueue!.dequeueAll();
    for (final batch in batches) {
      try {
        if (batch.signal == 'logs' && _logExporter != null) {
          final records = batch.events
              .map((e) => ScoutLogRecord(
                    severityNumber: e['severity_number'] as int? ?? 9,
                    severityText: e['severity_text'] as String? ?? 'INFO',
                    body: e['body'] as String? ?? '',
                    timestampNanos: BigInt.parse(
                        e['timestamp_nanos'] as String? ?? '0'),
                    attributes: Map<String, Object>.from(
                      Map<String, dynamic>.from(e)
                        ..removeWhere((k, _) => const {
                              'severity_number',
                              'severity_text',
                              'body',
                              'timestamp_nanos',
                            }.contains(k)),
                    ),
                  ))
              .toList();
          await _logExporter!.export(records);
        }
      } catch (_) {
        // Drop failed re-exports to avoid infinite loops
      }
    }
  }

  /// Reset all state for test isolation.
  @visibleForTesting
  static void resetForTesting() {
    _config = null;
    _breadcrumbManager.clear();
    _userId = null;
    _userEmail = null;
    _tapDetector = null;
    _longTaskDetector?.stop();
    _longTaskDetector = null;
    _frameMetricsCollector?.stop();
    _frameMetricsCollector = null;
    _nativeVitalsCollector?.stop();
    _nativeVitalsCollector = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _navObserver = null;
    _meter = null;
    _coldStartStopwatch = null;
    _coldStartRecorded = false;
    _warmStartStopwatch = null;
    _connectivityType = 'unknown';
    _sessionManager = null;
    _logger = null;
    _logExporter = null;
    _offlineQueue = null;
    _offlineFlushTimer?.cancel();
    _offlineFlushTimer = null;
    _dioInterceptor = null;
    if (_originalDebugPrint != null) {
      debugPrint = _originalDebugPrint!;
      _originalDebugPrint = null;
    }
  }
}
