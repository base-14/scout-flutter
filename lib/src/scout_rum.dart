import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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
import 'scope.dart';
import 'scout_logger.dart' as scout_log;
import 'scout_platform_channel.dart';
import 'scout_rum_config.dart';
import 'scout_session_sampler.dart';
import 'session_manager.dart';
import 'breadcrumb_manager.dart';
import 'crash_detector.dart';
import 'global_tap_detector.dart';
import 'scroll_observer.dart';
import 'uuid.dart';

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
  static Map<String, Object> _userAttributes = {};
  static GlobalTapDetector? _tapDetector;
  static LongTaskDetector? _longTaskDetector;
  static AppLifecycleListener? _lifecycleListener;

  /// Mirror of the most recently entered screen, updated by any
  /// observer instance returned from `navigatorObserver`. Decoupled
  /// from a specific observer so apps with nested Navigators (e.g.
  /// CupertinoTabView per tab) can attach a fresh observer to each
  /// without Flutter's "observer already has a navigator" assertion.
  static String? _currentScreenName;
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
  static StreamSubscription? _connectivitySubscription;
  static HttpOverrides? _previousHttpOverrides;
  static bool _flushing = false;
  static String? _activeTraceId;
  static String? _activeSpanId;
  static CrashDetector? _crashDetector;
  // Cross-session stable identifier — persisted to disk on first init,
  // hydrated on every subsequent launch. Attached as `enduser.anonymous_id`
  // on every span so backends can group sessions by user without
  // requiring an authenticated identity. Cleared by `clearUser()`.
  static String? _anonymousId;
  // Wall-clock when `initialize()` was called. Used for the
  // `error.time_since_app_start_ms` attribute so a backend can tell
  // crash-at-launch from crash-during-session at a glance.
  static int? _appStartedAtMs;
  // Most recent navigation. Fed into `view.referrer` on the next
  // screen_view emission. Reset on `clearUser()`-style scope flush.
  static String? _previousScreenName;
  static bool _hasNavigated = false;
  // Latest aggregated scroll metrics for the active screen. Decorated
  // onto the next emitted span via `_commonAttributes`. Reset on
  // navigation so each screen reports its own depth.
  static ScoutScrollMetrics? _latestScroll;
  // For INV (Interaction to Next View) vital — timestamp of the most
  // recent user_interaction and the screen it happened on. When a
  // screen_view fires soon after on a *different* screen, the delta
  // is the user-perceived navigation latency.
  static int? _lastInteractionAtMs;
  static String? _lastInteractionScreen;
  // Window after a tap during which a subsequent screen_view is
  // considered the navigation result of that tap. Anything later is
  // discarded — the user probably tapped, did something else, then
  // navigated by other means.
  static const int _invWindowMs = 5000;

  /// Current config, or null if not initialized.
  static ScoutFlutterConfig? get config => _config;

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _config != null;

  /// Access the breadcrumb manager.
  static BreadcrumbManager get breadcrumbManager => _breadcrumbManager;

  /// Current session ID.
  static String? get sessionId => _sessionManager?.sessionId;

  /// Stable per-install anonymous identifier (UUID v4), persisted to
  /// the temp directory and reused across launches until the install
  /// is removed. Exposed for the WebView bridge so embedded web pages
  /// can adopt the native identity.
  static String? get anonymousId => _anonymousId;

  /// Re-emit a span received from a bridged WebView. Used by
  /// `ScoutWebViewBridge`; not a stable public API for app code.
  ///
  /// Native common attributes (session_id, device.*, app.*, etc.) are
  /// merged on top so all spans share the native session even if the
  /// web payload carried its own. `span.source = "webview"` should be
  /// set by the caller.
  static void emitBridgedSpan(String type, Map<String, Object> attributes) {
    _emitSpan(type, {...attributes, ..._commonAttributes()});
  }

  /// Dio interceptor for custom Dio adapter users.
  static ScoutDioInterceptor get dioInterceptor {
    _dioInterceptor ??= ScoutDioInterceptor(
      firstPartyHosts: _config?.firstPartyHosts,
      onRequestCompleted: _onHttpRequestCompleted,
      onTraceContextCreated: (traceId, spanId) {
        _activeTraceId = traceId;
        _activeSpanId = spanId;
      },
    );
    return _dioInterceptor!;
  }

  /// Navigator observer for automatic screen tracking. Returns a
  /// fresh instance on every read so the same SDK can be attached to
  /// multiple `Navigator`s — root + per-tab CupertinoTabView, nested
  /// modal navigators, etc. All instances funnel events into shared
  /// static state so dashboards see one coherent screen timeline.
  static NavigatorObserver get navigatorObserver {
    return AutoNameNavigatorObserver(
      onScreenChanged: (screenName) {
        try {
          _currentScreenName = screenName;
          final isFirst = !_hasNavigated;
          _hasNavigated = true;
          _emitSpan('screen_view', {
            'screen.name': screenName,
            'view.id': uuidV4(),
            'view.loading_type': isFirst ? 'initial_load' : 'route_change',
            'view.is_active': true,
            if (_previousScreenName != null && !isFirst)
              'view.referrer': _previousScreenName!,
            ..._commonAttributes(),
          });
          // INV (Interaction to Next View) — if a tap happened on the
          // outgoing screen within the window, the elapsed time to
          // this new screen is the navigation latency the user felt.
          final tapAt = _lastInteractionAtMs;
          final tapScreen = _lastInteractionScreen;
          if (tapAt != null && tapScreen != null && tapScreen != screenName) {
            final invMs = DateTime.now().millisecondsSinceEpoch - tapAt;
            if (invMs >= 0 && invMs <= _invWindowMs) {
              _emitVital(
                'inv',
                durationMs: invMs,
                type: 'navigation',
                extra: {
                  'vital.from_screen': tapScreen,
                  'vital.to_screen': screenName,
                },
              );
            }
          }
          _lastInteractionAtMs = null;
          _lastInteractionScreen = null;

          _previousScreenName = screenName;
          _latestScroll = null;
          ScoutScrollObserver.resetGlobal();
          _crashDetector?.updateLastScreen(screenName);
          addBreadcrumb('navigation', 'screen: $screenName');
        } catch (_) {}
      },
      onScreenLoadTime: (screenName, loadTime) {
        try {
          _emitSpan('screen_load', {
            'screen.name': screenName,
            'screen.load_time': loadTime.inMilliseconds / 1000.0,
            ..._commonAttributes(),
          });
        } catch (_) {}
      },
      onScreenEnter: (screenName) {
        try {
          if (!isInitialized) return;
          addBreadcrumb('view_session', 'entered: $screenName');
        } catch (_) {}
      },
      onScreenExit: (screenName, timeSpent) {
        try {
          _emitSpan('view_session', {
            'screen.name': screenName,
            'view.time_spent': timeSpent.inMilliseconds / 1000.0,
            ..._commonAttributes(),
          });
          addBreadcrumb(
            'view_session',
            'exited: $screenName (${timeSpent.inMilliseconds}ms)',
          );
        } catch (_) {}
      },
    );
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
    _appStartedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    WidgetsFlutterBinding.ensureInitialized();

    // Install error handlers and crash detector FIRST — before any async
    // work that could fail. This ensures Dart exceptions during
    // initialization itself are captured and persisted to disk.
    try {
      final tempDir = await getTemporaryDirectory();
      _crashDetector = CrashDetector(
        directory: Directory('${tempDir.path}/scout_crash'),
      );
    } catch (_) {
      // If we can't even create the crash detector, continue without it.
    }
    if (config.enableErrorTracking) {
      _setupErrorHandlers();
    }

    // Wrap the rest of initialization — SDK failure must never crash the app.
    try {
      await _initializeCore(config);
    } catch (e) {
      debugPrint('ScoutFlutter: initialization failed: $e');
    }
  }

  static Future<void> _initializeCore(ScoutFlutterConfig config) async {
    final tempDir = await getTemporaryDirectory();

    // Hydrate (or mint + persist) the cross-session anonymous user id.
    // Stored under the app's Documents dir so it survives cache wipes
    // and Flutter hot restarts. Failure is non-fatal — we just lose
    // cross-session correlation for this run.
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final anonFile = File('${docsDir.path}/scout_anonymous_id');
      if (await anonFile.exists()) {
        _anonymousId = (await anonFile.readAsString()).trim();
      }
      if (_anonymousId == null || _anonymousId!.isEmpty) {
        _anonymousId = uuidV4();
        await anonFile.writeAsString(_anonymousId!);
      }
    } catch (_) {
      // Storage failed — fall back to in-memory only for this session.
      _anonymousId ??= uuidV4();
    }

    final resourceAttrs = <String, Object>{
      if (config.environment != null) 'environment': config.environment!,
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
      OtlpHttpExporterConfig(endpoint: httpEndpoint, headers: config.headers),
    );

    await FlutterOTel.initialize(
      serviceName: config.serviceName,
      serviceVersion: config.serviceVersion,
      tracerName: kScopeName,
      tracerVersion: kScopeVersion,
      endpoint: httpEndpoint,
      secure: config.secure,
      enableMetrics: config.enablePerformanceMetrics,
      sampler: ScoutSessionSampler(
        sessionResolver: () => _sessionManager,
        alwaysCaptureErrors: config.alwaysCaptureErrors,
      ),
      spanProcessor: BatchSpanProcessor(spanExporter),
      // Use our fixed exporter to work around the frozen protobuf bug
      // in dartastic_opentelemetry's OtlpHttpMetricExporter.
      // See: https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/1
      metricExporter:
          config.enablePerformanceMetrics
              ? FixedHttpMetricExporter(
                endpoint: httpEndpoint,
                headers: config.headers,
              )
              : null,
      resourceAttributes:
          resourceAttrs.isEmpty ? null : resourceAttrs.toAttributes(),
    );

    _config = config;

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
      _meter = FlutterOTel.meter(name: kScopeName, version: kScopeVersion);
      _setupFrameMetrics();
      _setupNativeVitals();
    }

    if (config.enableStartupTracking) {
      _measureColdStart();
    }

    if (config.enableConnectivityTracking) {
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
        result,
      ) {
        try {
          if (result.isNotEmpty) {
            _connectivityType = result.first.name;
          }
          _flushOfflineQueue();
        } catch (_) {}
      });
    }

    // --- Phase 3: Session, Logging, Network, Offline ---

    // Session manager
    _sessionManager = SessionManager(
      sampleRate: config.sessionSampleRate,
      timeoutMinutes: config.sessionTimeoutMinutes,
    );

    // Offline queue + crash detection
    final offlineDir = Directory('${tempDir.path}/scout_offline');
    _offlineQueue = OfflineQueue(
      directory: offlineDir,
      maxStorageMb: config.maxOfflineStorageMb,
      enabled: config.offlineBufferEnabled,
      maxItemsPerSignal: {
        'traces': config.offlineMaxTraceItems,
        'metrics': config.offlineMaxMetricItems,
        'logs': config.offlineMaxLogItems,
      },
    );

    // Crash detection — check previous session before writing new marker.
    try {
      final previousCrash = await _crashDetector?.checkPreviousCrash();
      if (previousCrash != null) {
        // Extract error details from breadcrumbs for a self-contained crash span.
        String? lastErrorType;
        String? lastErrorMessage;
        if (previousCrash.breadcrumbs != null) {
          try {
            final crumbs = json.decode(previousCrash.breadcrumbs!) as List;
            for (var i = crumbs.length - 1; i >= 0; i--) {
              final c = crumbs[i] as Map<String, dynamic>;
              if (c['type'] == 'error') {
                final msg = c['message'] as String? ?? '';
                // Breadcrumb message format: "flutter_error: <exception>"
                final colonIdx = msg.indexOf(': ');
                if (colonIdx > 0) {
                  lastErrorType = msg.substring(0, colonIdx);
                  lastErrorMessage = msg.substring(colonIdx + 2);
                } else {
                  lastErrorType = 'error';
                  lastErrorMessage = msg;
                }
                break;
              }
            }
          } catch (_) {}
        }

        // Use the CRASHED session's ID and timestamp, not the new session.
        final crashTime = previousCrash.lastActiveAt ?? previousCrash.startedAt;
        _emitSpan('app_crash', {
          'session.id': previousCrash.sessionId,
          'crash.previous_session_id': previousCrash.sessionId,
          'crash.started_at': previousCrash.startedAt.toIso8601String(),
          'crash.timestamp': crashTime.toIso8601String(),
          'crash.status': previousCrash.status,
          if (previousCrash.lastScreen != null)
            'crash.last_screen': previousCrash.lastScreen!,
          if (lastErrorType != null) 'error.type': lastErrorType,
          if (lastErrorMessage != null) 'error.message': lastErrorMessage,
          if (previousCrash.breadcrumbs != null)
            'breadcrumbs': previousCrash.breadcrumbs!,
          ..._userAttributes,
          if (_connectivityType != 'unknown')
            'network.connection.type': _connectivityType,
        });
      }
      await _crashDetector?.markSessionStarted(
        sessionId: _sessionManager!.sessionId,
      );
    } catch (_) {}

    // Drain every native-side crash pipeline. Three orthogonal sources:
    //   1. KSCrash (iOS) / JVM uncaught + JNI signal handler (Android) —
    //      written at the moment of crash to disk in-process.
    //   2. MetricKit (iOS 14+) — delayed payloads the OS attributes
    //      asynchronously, including crashes/hangs we missed because
    //      we couldn't write to disk in time.
    //   3. ApplicationExitInfo (Android API 30+) — every process death
    //      the kernel knew about: ANR, OOM kill, native crash, etc.
    // All three feed the same `native_crash` span shape so the
    // backend doesn't need to branch on source.
    await _drainCrashReports();

    // Periodic offline flush (every 60 seconds)
    _offlineFlushTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      try {
        _flushOfflineQueue();
      } catch (_) {}
    });

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
          try {
            if (message != null) {
              _logger?.logInfo(message);
            }
          } catch (_) {}
        };
      }
    }

    // HTTP tracking via HttpOverrides
    if (config.enableNetworkTracking) {
      _previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = ScoutHttpOverrides(
        existingOverrides: _previousHttpOverrides,
        exportEndpoint: httpEndpoint,
        ignorePatterns: config.ignoreUrlPatterns,
        firstPartyHosts: config.firstPartyHosts,
        onRequestCompleted: _onHttpRequestCompleted,
        onTraceContextCreated: (traceId, spanId) {
          _activeTraceId = traceId;
          _activeSpanId = spanId;
        },
      );
    }
  }

  /// Applies the beforeSend callback. Returns the (possibly modified) attributes,
  /// or null if the event should be dropped.
  static Map<String, Object>? _applyBeforeSend(
    String type,
    String name,
    Map<String, Object> attributes,
  ) {
    if (_config?.beforeSend == null) return attributes;
    final event = <String, dynamic>{'type': type, 'name': name, ...attributes};
    final result = _config!.beforeSend!(event);
    if (result == null) return null;
    final filtered = <String, Object>{};
    for (final entry in result.entries) {
      if (entry.key != 'type' && entry.key != 'name') {
        final value = entry.value;
        if (value != null && value is Object) {
          filtered[entry.key] = value;
        }
      }
    }
    return filtered;
  }

  /// Creates and immediately ends a span, subject to sampling and beforeSend.
  static void _emitSpan(String name, Map<String, Object> attributes) {
    if (!isInitialized) return;
    final alwaysOn =
        (_config?.alwaysCaptureErrors ?? true) &&
        kErrorClassSpans.contains(name);
    if (!alwaysOn && !(_sessionManager?.isSampled ?? true)) return;

    final filtered = _applyBeforeSend('span', name, attributes);
    if (filtered == null) return;

    final span = FlutterOTel.tracer.startSpan(
      name,
      attributes: filtered.isEmpty ? null : filtered.toAttributes(),
    );

    // Set active trace context so logs emitted around the same time
    // (e.g. debugPrint from error boundaries) get correlated.
    try {
      final ctx = span.spanContext;
      _activeTraceId = ctx.traceId.toString();
      _activeSpanId = ctx.spanId.toString();
    } catch (_) {}

    span.end();
  }

  /// Emits a "vital" — a user-defined or framework-defined
  /// timing of interest (FBC, INV, custom feature-operation vitals).
  /// All vitals share the `app_vital` span type with `vital.name` so
  /// dashboards can chart any subset.
  static void _emitVital(
    String vitalName, {
    required int durationMs,
    String? type,
    Map<String, Object>? extra,
  }) {
    _emitSpan('app_vital', {
      'vital.name': vitalName,
      'vital.duration': durationMs / 1000.0,
      'vital.duration_ms': durationMs,
      if (type != null) 'vital.type': type,
      if (extra != null) ...extra,
      ..._commonAttributes(),
    });
  }

  static void _setupGlobalTapDetection(ScoutFlutterConfig config) {
    _tapDetector = GlobalTapDetector(
      customGestureDetector: config.customGestureDetector,
      onTapDetected: (details) {
        try {
          _emitSpan('user_interaction', {
            'user_interaction.id': uuidV4(),
            'user_interaction.type': 'tap',
            'user_interaction.target': details.elementDescription,
            'user_interaction.target.type': details.elementName,
            'user_interaction.target.name_source': details.nameSource,
            'user_interaction.target.permanent_id': details.permanentId,
            'user_interaction.target.x': details.position.dx.round(),
            'user_interaction.target.y': details.position.dy.round(),
            ..._commonAttributes(),
          });
          addBreadcrumb(
            'tap',
            '${details.elementName}: ${details.elementDescription}',
          );
          // Arm INV: if the next screen_view fires on a *different*
          // screen within _invWindowMs, that delta becomes the
          // Interaction-to-Next-View vital.
          _lastInteractionAtMs = DateTime.now().millisecondsSinceEpoch;
          _lastInteractionScreen = _previousScreenName;
        } catch (_) {}
      },
    );
    _tapDetector!.start();
  }

  /// Synchronously drain every in-flight exporter (trace + metric +
  /// log) to disk / network. Best-effort: each `forceFlush` call is
  /// wrapped in a try/catch so a misbehaving exporter can't block
  /// the AppLifecycleListener and freeze the host on background.
  static void _forceFlushAll() {
    try {
      FlutterOTel.forceFlush();
    } catch (_) {}
  }

  static void _setupLifecycleTracking() {
    _lifecycleListener = AppLifecycleListener(
      onInactive: () {
        try {
          if (_config?.enableStartupTracking == true) {
            _warmStartStopwatch = Stopwatch()..start();
          }
        } catch (_) {}
      },
      onPause: () {
        try {
          _sessionManager?.onBackground();
          _crashDetector?.markSessionPaused();
          addBreadcrumb('lifecycle', 'app_paused');
          // Flush every in-flight span / metric / log batch before
          // the OS suspends or kills us. Without this, taps emitted
          // in the last ~5s (the BatchSpanProcessor's default
          // scheduledDelayMillis) die with the process and are
          // missing from the next-launch replay.
          _forceFlushAll();
        } catch (_) {}
      },
      onResume: () {
        try {
          _sessionManager?.onForeground();
          _crashDetector?.markSessionResumed();
          addBreadcrumb('lifecycle', 'app_resumed');
          if (_config?.enableStartupTracking == true) {
            _measureWarmStart();
          }
        } catch (_) {}
      },
      onExitRequested: () async {
        try {
          addBreadcrumb('lifecycle', 'app_exit_requested');
        } catch (_) {}
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
      // FBC (First Build Complete) — emitted as a vital so dashboards
      // can chart it alongside INV without joining on app_startup.
      // Uses the same cold-start measurement: SDK init → first
      // post-frame callback. Process-start-to-first-frame (which
      // would require an OS-level start time) is a future refinement.
      _emitVital('fbc', durationMs: duration.inMilliseconds, type: 'startup');
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
        try {
          String? currentScreen;
          if (_currentScreenName != null) {
            currentScreen = _currentScreenName;
          }
          _emitSpan('long_task', {
            'long_task.duration': duration.inMilliseconds / 1000.0,
            'long_task.threshold': config.longTaskThresholdMs / 1000.0,
            if (currentScreen != null) 'screen.name': currentScreen,
            ..._commonAttributes(),
          });
          addBreadcrumb('long_task', 'Long task: ${duration.inMilliseconds}ms');
        } catch (_) {}
      },
    );
    _longTaskDetector!.start();
  }

  static Future<void> _setupAnrDetection(ScoutFlutterConfig config) async {
    ScoutPlatformChannel.setAnrHandler((durationMs) {
      try {
        String? currentScreen;
        if (_currentScreenName != null) {
          currentScreen = _currentScreenName;
        }
        _emitSpan('anr', {
          'anr.duration': durationMs / 1000.0,
          'anr.threshold': config.anrThresholdMs / 1000.0,
          if (currentScreen != null) 'screen.name': currentScreen,
          ..._commonAttributes(),
        });
        addBreadcrumb('anr', 'App not responding: ${durationMs}ms');
      } catch (_) {}
    });
    await ScoutPlatformChannel.startAnrDetection(
      thresholdMs: config.anrThresholdMs,
    );

    // iOS-only sub-ANR hang detector. Different threshold (250 ms vs
    // 5 s), different span type (`ui_hang`), runs as a second
    // watchdog. Skipped if user set iosHangThresholdMs to 0 or if we
    // aren't on iOS.
    if (Platform.isIOS && config.iosHangThresholdMs > 0) {
      ScoutPlatformChannel.setUiHangHandler((durationMs) {
        try {
          String? currentScreen;
          if (_currentScreenName != null) {
            currentScreen = _currentScreenName;
          }
          _emitSpan('ui_hang', {
            'ui_hang.duration': durationMs / 1000.0,
            'ui_hang.threshold': config.iosHangThresholdMs / 1000.0,
            if (currentScreen != null) 'screen.name': currentScreen,
            ..._commonAttributes(),
          });
          addBreadcrumb('ui_hang', 'UI hang: ${durationMs}ms');
        } catch (_) {}
      });
      await ScoutPlatformChannel.startUiHangDetection(
        thresholdMs: config.iosHangThresholdMs,
      );
    }
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
        try {
          if (!(_sessionManager?.isSampled ?? true)) return;
          final screenAttr =
              <String, Object>{
                if (_currentScreenName != null)
                  'screen.name': _currentScreenName!,
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
        } catch (_) {}
      },
      onFrozenFrame: (duration) {
        try {
          String? currentScreen;
          if (_currentScreenName != null) {
            currentScreen = _currentScreenName;
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
        } catch (_) {}
      },
    );
    _frameMetricsCollector!.start();
  }

  static void _setupNativeVitals() {
    // Get the SDK Meter directly, bypassing UIMeter which has a broken
    // createGauge cast (UIMeter casts APIGauge as Gauge, which fails).
    final sdkMeter = FlutterOTel.meterProvider.delegate.getMeter(
      name: kScopeName,
      version: kScopeVersion,
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
        try {
          if (!(_sessionManager?.isSampled ?? true)) return;
          final attrs =
              <String, Object>{
                if (_currentScreenName != null)
                  'screen.name': _currentScreenName!,
                if (_sessionManager != null)
                  'session.id': _sessionManager!.sessionId,
              }.toAttributes();
          memoryGauge.record(usedBytes.toDouble(), attrs);
        } catch (_) {}
      },
      onCpu: (cpuPercent) {
        try {
          if (!(_sessionManager?.isSampled ?? true)) return;
          final attrs =
              <String, Object>{
                if (_currentScreenName != null)
                  'screen.name': _currentScreenName!,
                if (_sessionManager != null)
                  'session.id': _sessionManager!.sessionId,
              }.toAttributes();
          cpuGauge.record(cpuPercent, attrs);
        } catch (_) {}
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

  static FlutterExceptionHandler? _wrappedFlutterErrorHandler;
  static ErrorCallback? _wrappedPlatformErrorHandler;

  static void _setupErrorHandlers() {
    _wrapFlutterErrorHandler();
    _wrapPlatformErrorHandler();

    // Re-wrap once after the first frame. This catches overwrites from
    // widget initState() and service initialize() calls that run after
    // Scout but before the first frame renders. Zero ongoing cost.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _wrapFlutterErrorHandler();
      _wrapPlatformErrorHandler();
    });
  }

  /// Wraps [FlutterError.onError] so Scout's telemetry runs before the
  /// app's handler. Skips if already wrapped.
  static void _wrapFlutterErrorHandler() {
    final current = FlutterError.onError;
    if (current == null || current == _wrappedFlutterErrorHandler) return;

    final appHandler = current;
    _wrappedFlutterErrorHandler = (FlutterErrorDetails details) {
      try {
        _recordAndPersistBreadcrumb(
          'error',
          'flutter_error: ${details.exception.runtimeType}',
        );
        _emitSpan(
          'error',
          _errorAttributes(
            type: 'flutter_error',
            error: details.exception,
            stackTrace: details.stack,
            library: details.library,
            source: 'source',
            handling: 'handled',
          ),
        );
      } catch (_) {}
      appHandler(details);
    };
    FlutterError.onError = _wrappedFlutterErrorHandler;
  }

  /// Wraps [PlatformDispatcher.instance.onError] so Scout's telemetry runs
  /// before the app's handler. Skips if already wrapped.
  static void _wrapPlatformErrorHandler() {
    final current = PlatformDispatcher.instance.onError;
    if (current == _wrappedPlatformErrorHandler) return;

    final appHandler = current;
    _wrappedPlatformErrorHandler = (Object error, StackTrace stack) {
      try {
        _recordAndPersistBreadcrumb(
          'error',
          'uncaught_error: ${error.runtimeType}',
        );
        _emitSpan(
          'error',
          _errorAttributes(
            type: 'uncaught_error',
            error: error,
            stackTrace: stack,
            source: 'source',
            handling: 'unhandled',
          ),
        );
      } catch (_) {}
      if (appHandler != null) return appHandler(error, stack);
      return true;
    };
    PlatformDispatcher.instance.onError = _wrappedPlatformErrorHandler;
  }

  /// Get breadcrumbs JSON safely — never throws.
  static String _safeBreadcrumbsJson() {
    try {
      return _breadcrumbManager.toJsonString();
    } catch (_) {
      return '[]';
    }
  }

  /// Stack traces longer than this are truncated; the span carries
  /// `error.was_truncated: true` so the backend can flag it.
  static const _maxStackChars = 8000;

  /// Build the common `error.*` attribute bundle every emission site
  /// uses. Centralises fingerprint computation, stack truncation, and
  /// causes-chain walking so the three call sites stay in lockstep.
  static Map<String, Object> _errorAttributes({
    required String type,
    required Object error,
    StackTrace? stackTrace,
    String? library,
    required String source,
    required String handling,
  }) {
    final stackString = stackTrace?.toString() ?? '';
    final wasTruncated = stackString.length > _maxStackChars;
    final stack =
        wasTruncated ? stackString.substring(0, _maxStackChars) : stackString;

    // Fingerprint: short stable hash of (error type + first stack frame
    // + message). Mirrors `error.fingerprint` in DD / scout_react —
    // lets the backend group recurrences of the same error without
    // requiring identical full stack traces.
    final firstFrame = stack
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final fingerprint = djb2Hash(
      '${error.runtimeType}|${error.toString()}|$firstFrame',
    );

    // Causes chain — Dart 3 `Error.cause` is rare in user code, but
    // some Flutter framework errors and `package:async`-wrapped
    // futures expose it. Walk up to 5 deep to bound payload size.
    final causes = _collectErrorCauses(error);

    return {
      'error.id': uuidV4(),
      'error.type': type,
      'error.message': error.toString(),
      'error.stack_trace': stack,
      'error.handled': handling == 'handled' ? 'true' : 'false',
      'error.handling': handling,
      'error.source': source,
      'error.source_type': 'flutter',
      'error.fingerprint': fingerprint,
      if (wasTruncated) 'error.was_truncated': true,
      if (library != null && library.isNotEmpty) 'error.library': library,
      if (causes.isNotEmpty) 'error.causes_json': jsonEncode(causes),
      if (_appStartedAtMs != null)
        'error.time_since_app_start_ms':
            DateTime.now().millisecondsSinceEpoch - _appStartedAtMs!,
      'breadcrumbs': _safeBreadcrumbsJson(),
      ..._commonAttributes(),
    };
  }

  static List<Map<String, String?>> _collectErrorCauses(Object error) {
    final out = <Map<String, String?>>[];
    Object? cur = error;
    var depth = 0;
    while (cur is Error && cur.toString().isNotEmpty && depth < 5) {
      final stack = cur.stackTrace?.toString();
      out.add({
        'message': cur.toString(),
        'type': cur.runtimeType.toString(),
        if (stack != null && stack.isNotEmpty)
          'stack': stack.length > 2000 ? stack.substring(0, 2000) : stack,
      });
      // Dart Error has no standard `cause` field; the chain stops here
      // unless the framework subclassed it. Loop guard keeps this safe.
      break; // placeholder until a richer chain extraction lands
    }
    if (depth == 0 && out.isEmpty) return const [];
    return out;
  }

  /// Pull every kind of native crash signal we can — KSCrash on iOS,
  /// in-process JVM + JNI on Android, MetricKit, ApplicationExitInfo —
  /// and emit each as a `native_crash` span with the full attribute set.
  static Future<void> _drainCrashReports() async {
    final sources = <Future<List<Map<String, dynamic>>>>[
      ScoutPlatformChannel.getNativeCrashReports(),
      ScoutPlatformChannel.getMetricKitReports(),
      ScoutPlatformChannel.getExitInfoReports(),
    ];
    final results = await Future.wait(
      sources.map((f) => f.catchError((_) => <Map<String, dynamic>>[])),
    );
    for (final list in results) {
      for (final crash in list) {
        try {
          _emitSpan('native_crash', _crashAttributes(crash));
        } catch (_) {
          /* never crash the host while reporting a crash */
        }
      }
    }
  }

  /// Flatten one platform-side crash dict into the OTel attribute map
  /// we ship on `native_crash` spans. Snake_case → dotted, with
  /// platform-specific keys passed through untouched so a backend that
  /// understands the iOS Mach world doesn't lose `mach_exception` /
  /// `mach_code` data and an Android backend doesn't lose
  /// `subreason` / `tombstone`.
  static Map<String, Object> _crashAttributes(Map<String, dynamic> crash) {
    Object? v(String k) => crash[k];
    String? s(String k) {
      final x = v(k);
      return x is String && x.isNotEmpty ? x : null;
    }

    final out = <String, Object>{
      'crash.type': s('crash_type') ?? 'unknown',
      'crash.reason': s('crash_reason') ?? 'unknown',
      'crash.timestamp': s('crash_timestamp') ?? '',
    };

    // Common platform fields
    final passthroughString = <String, String>{
      'crash.thread': 'crash_thread',
      'crash.thread_name': 'crash_thread_name',
      'crash.stack_trace': 'crash_stack_trace',
      'crash.signal': 'crash_signal',
      'crash.signal_code': 'crash_signal_code',
      'crash.signal_address': 'crash_signal_address',
      'crash.mach_exception': 'crash_mach_exception',
      'crash.mach_code': 'crash_mach_code',
      'crash.mach_subcode': 'crash_mach_subcode',
      'crash.nsexception_name': 'crash_nsexception_name',
      'crash.cpu_arch': 'crash_cpu_arch',
      'crash.build_type': 'crash_build_type',
      'crash.os_name': 'crash_os_name',
      'crash.os_version': 'crash_os_version',
      'crash.kernel_version': 'crash_kernel_version',
      'crash.device_model': 'crash_device_model',
      'crash.machine': 'crash_machine',
      'crash.process_name': 'crash_process_name',
      'crash.report_id': 'crash_report_id',
      'crash.registers_json': 'crash_registers_json',
      'crash.callstack_tree_json': 'crash_callstack_tree_json',
      'crash.binary_images_json': 'crash_binary_images_json',
      // Android-specific
      'crash.abi': 'crash_abi',
      'crash.build_fingerprint': 'crash_build_fingerprint',
      'crash.kernel': 'crash_kernel',
      'crash.registers': 'crash_registers',
      'crash.memory_map': 'crash_memory_map',
      'crash.tombstone': 'crash_tombstone',
      'crash.app_version': 'crash_app_version',
    };
    passthroughString.forEach((dotKey, snakeKey) {
      final value = s(snakeKey);
      if (value != null) out[dotKey] = value;
    });

    // Numeric platform fields
    final passthroughNumeric = <String, String>{
      'crash.pid': 'crash_pid',
      'crash.tid': 'crash_tid',
      'crash.uid': 'crash_uid',
      'crash.process_uptime_secs': 'crash_process_uptime_secs',
      'crash.subreason': 'crash_subreason',
      'crash.exit_status': 'crash_exit_status',
      'crash.importance': 'crash_importance',
      'crash.pss_kb': 'crash_pss_kb',
      'crash.rss_kb': 'crash_rss_kb',
      'crash.death_timestamp_ms': 'crash_death_timestamp_ms',
    };
    passthroughNumeric.forEach((dotKey, snakeKey) {
      final value = v(snakeKey);
      if (value is num) out[dotKey] = value;
    });

    // Context attached to every span (session.id, enduser.*, etc.)
    out.addAll(_commonAttributes());
    return out;
  }

  /// Record a breadcrumb and persist to disk for crash survival.
  static void _recordAndPersistBreadcrumb(String type, String message) {
    try {
      _breadcrumbManager.record(type, message);
      _crashDetector?.persistBreadcrumbs(_safeBreadcrumbsJson());
    } catch (_) {
      // Never crash the app due to telemetry failure.
    }
  }

  /// Record a breadcrumb for error context.
  static void addBreadcrumb(String type, String message) {
    _recordAndPersistBreadcrumb(type, message);
  }

  /// Report an error manually.
  static void reportError(Object error, StackTrace? stackTrace) {
    try {
      _recordAndPersistBreadcrumb(
        'error',
        'manual_error: ${error.runtimeType}',
      );
      _emitSpan(
        'error',
        _errorAttributes(
          type: 'manual_error',
          error: error,
          stackTrace: stackTrace,
          source: 'custom',
          handling: 'handled',
        ),
      );
    } catch (_) {
      // Never crash the app due to telemetry failure.
    }
  }

  /// Set user identity. Attached to subsequent spans.
  /// [id] is required. Pass any additional attributes as key-value pairs.
  static void setUser({required String id, Map<String, Object>? attributes}) {
    _userAttributes = {'enduser.id': id, ...?attributes};
  }

  /// Clear user identity.
  static void clearUser() {
    _userAttributes = {};
  }

  static Map<String, Object> _commonAttributes() {
    final m = _latestScroll;
    return {
      ..._userAttributes,
      if (_anonymousId != null) 'enduser.anonymous_id': _anonymousId!,
      if (_connectivityType != 'unknown')
        'network.connection.type': _connectivityType,
      if (_sessionManager != null) 'session.id': _sessionManager!.sessionId,
      // DD parity: distinguishes user sessions from synthetic / ci-test
      // traffic. Today we only emit user-driven traffic, so this is
      // always 'user'.
      'session.type': 'user',
      if (m != null) ...{
        'display.scroll.max_depth': m.maxDepth.round(),
        'display.scroll.max_depth_scroll_top': m.maxDepthScrollTop.round(),
        'display.scroll.max_scroll_height': m.maxScrollHeight.round(),
        'display.scroll.max_scroll_height_time_ms': m.maxScrollHeightTimeMs,
      },
    };
  }

  /// Wrap your app's root widget to enable per-screen scroll-depth
  /// tracking. One line in the app's entry point:
  ///
  /// ```dart
  /// runApp(ScoutFlutter.observeScroll(child: MyApp()));
  /// ```
  ///
  /// Every scroll event decorates the next emitted span with
  /// `display.scroll.max_depth`, `max_depth_scroll_top`,
  /// `max_scroll_height`, `max_scroll_height_time_ms`. Accumulators
  /// reset on each navigation transition.
  static Widget observeScroll({required Widget child}) {
    return ScoutScrollObserver(
      child: child,
      onMetrics: (m) => _latestScroll = m,
    );
  }

  /// Current user ID, if set.
  static String? get userId => _userAttributes['enduser.id'] as String?;

  /// Current user attributes.
  static Map<String, Object> get userAttributes =>
      Map.unmodifiable(_userAttributes);

  /// Access the OTel tracer for custom spans.
  static dynamic get tracer => FlutterOTel.tracer;

  /// Log a custom business event as a span.
  static void logEvent(String name, {Map<String, dynamic>? attributes}) {
    final attrMap = <String, Object>{..._commonAttributes(), ...?attributes};
    _emitSpan(name, attrMap);
  }

  /// Log a structured message.
  static void log(
    scout_log.LogLevel level,
    String message, {
    Map<String, Object>? attributes,
  }) {
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
    try {
      if (!isInitialized) return;
      if (!(_sessionManager?.isSampled ?? true)) return;

      final attributes = _applyBeforeSend('span', 'http.request', {
        'http.method': data.method,
        'http.url': data.url.toString(),
        'http.status_code': data.statusCode,
        'http.response_content_length': data.responseSize,
        'http.duration_ms': data.durationMs,
        if (data.error != null) 'http.error': data.error!,
        ..._commonAttributes(),
      });
      if (attributes == null) return;

      final span = FlutterOTel.tracer.startSpan(
        'http.request',
        attributes: attributes.isEmpty ? null : attributes.toAttributes(),
      );
      if (data.error != null) {
        span.setStatus(SpanStatusCode.Error, data.error!);
      }
      span.end();

      // Clear trace context now that the request is complete.
      _activeTraceId = null;
      _activeSpanId = null;
    } catch (_) {}
  }

  static void _onLogEntry(scout_log.ScoutLogEntry entry) {
    try {
      final alwaysOn =
          (_config?.alwaysCaptureErrors ?? true) &&
          entry.level == scout_log.LogLevel.error;
      if (!alwaysOn && !(_sessionManager?.isSampled ?? true)) return;

      final logAttrs = <String, Object>{
        'session.id': _sessionManager?.sessionId ?? '',
        if (_currentScreenName != null) 'screen.name': _currentScreenName!,
        ..._userAttributes,
        ...?entry.attributes,
      };

      // Apply beforeSend — user can modify message/attributes or drop the log.
      String body = entry.message;
      if (_config?.beforeSend != null) {
        final event = <String, dynamic>{
          'type': 'log',
          'severity': entry.level.severityText,
          'message': entry.message,
          ...logAttrs,
        };
        final result = _config!.beforeSend!(event);
        if (result == null) return;
        // Use possibly modified message
        body = (result['message'] as String?) ?? entry.message;
      }

      final logRecord = ScoutLogRecord(
        severityNumber: entry.level.severityNumber,
        severityText: entry.level.severityText,
        body: body,
        timestampNanos:
            BigInt.from(entry.timestamp.microsecondsSinceEpoch) *
            BigInt.from(1000),
        attributes: logAttrs,
        traceId: _activeTraceId,
        spanId: _activeSpanId,
      );
      _logExporter
          ?.export([logRecord])
          .then((success) {
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
          })
          .catchError((_) {
            // Silently handle export errors
          });
    } catch (_) {}
  }

  static Future<void> _flushOfflineQueue() async {
    if (_flushing || _offlineQueue == null) return;
    _flushing = true;
    try {
      final batches = await _offlineQueue!.dequeueAll();
      for (final batch in batches) {
        try {
          if (batch.signal == 'logs' && _logExporter != null) {
            final records =
                batch.events
                    .map(
                      (e) => ScoutLogRecord(
                        severityNumber: e['severity_number'] as int? ?? 9,
                        severityText: e['severity_text'] as String? ?? 'INFO',
                        body: e['body'] as String? ?? '',
                        timestampNanos: BigInt.parse(
                          e['timestamp_nanos'] as String? ?? '0',
                        ),
                        attributes: Map<String, Object>.from(
                          Map<String, dynamic>.from(e)..removeWhere(
                            (k, _) => const {
                              'severity_number',
                              'severity_text',
                              'body',
                              'timestamp_nanos',
                            }.contains(k),
                          ),
                        ),
                      ),
                    )
                    .toList();
            await _logExporter!.export(records);
          }
        } catch (_) {
          // Drop failed re-exports to avoid infinite loops
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// Reset all state for test isolation.
  @visibleForTesting
  static void resetForTesting() {
    _config = null;
    _breadcrumbManager.clear();
    _userAttributes = {};
    _tapDetector?.stop();
    _tapDetector = null;
    _longTaskDetector?.stop();
    _longTaskDetector = null;
    _frameMetricsCollector?.stop();
    _frameMetricsCollector = null;
    _nativeVitalsCollector?.stop();
    _nativeVitalsCollector = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _currentScreenName = null;
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
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    if (_previousHttpOverrides != null) {
      HttpOverrides.global = _previousHttpOverrides;
      _previousHttpOverrides = null;
    }
    _flushing = false;
    _activeTraceId = null;
    _activeSpanId = null;
    _crashDetector = null;
  }
}
