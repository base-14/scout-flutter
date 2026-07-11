Scout Flutter SDK — Integration Guide

Real User Monitoring for Flutter apps. One package, one function call — you get full visibility into crashes, errors, performance, and user behavior via OpenTelemetry.


GETTING STARTED

1. Add the dependency

Install from pub.dev:

  flutter pub add scout_flutter

This pins the latest published version in your pubspec.yaml automatically. See the package page for the current version: https://pub.dev/packages/scout_flutter


2. Initialize the SDK

In your main.dart, call initialize() before runApp():

import 'package:scout_flutter/scout_flutter.dart';

Future<void> main() async {
  await ScoutFlutter.initialize(
    config: ScoutFlutterConfig(
      serviceName: 'my-app',
      endpoint: 'https://otel.your-domain.com:4318',
    ),
  );
  runApp(const MyApp());
}

That's it. The SDK starts collecting data immediately.


3. Add navigation tracking (recommended)

To track screen views, screen load times, and view sessions, add the navigator observer:

MaterialApp(
  navigatorObservers: [ScoutFlutter.navigatorObserver],
)


4. Add Dio support (if using Dio)

If your app uses Dio for HTTP, add the interceptor:

final dio = Dio();
dio.interceptors.add(ScoutFlutter.dioInterceptor);

Apps using dart:io HttpClient are tracked automatically — no extra setup needed.


────────────────────────────────────────────────


WHAT THE SDK COLLECTS

Everything below is collected automatically after calling initialize(). No code changes required unless noted.


Crashes

| What | Span Name | How It Works |
|------|-----------|--------------|
| Native crashes (SIGSEGV, SIGABRT, etc.) | native_crash | Signal handler on Android, KSCrash on iOS. Captures full stack trace, registers, memory map. Reported on next app launch. |
| JVM/NSException crashes | native_crash | Uncaught JVM exceptions (Android) and NSExceptions (iOS). Written to disk, reported on next launch. |
| OOM / SIGKILL / exit() crashes | app_crash | Session marker file detects abnormal termination. Reported on next launch with breadcrumb trail. |
| Android OS post-mortems | native_crash | ApplicationExitInfo records drained on launch. Only crash-class reasons are reported (anr, jvm_crash, native_crash, low_memory) — normal exits (user swiped the app away, Force Stop, exit()) are never counted as crashes. Each record is reported exactly once; a persisted watermark prevents re-reporting on later launches. |

Crash spans include:
- crash.type — mach, signal, nsexception, jvm_exception, jvm_crash, anr, etc.
- crash.reason — EXC_BAD_ACCESS, SIGSEGV, NullPointerException, etc.
- crash.stack_trace — Full stack trace from the crashed thread
- crash.thread_name — Thread that crashed
- Previous session's breadcrumbs — Last user actions before the crash

Note on Android JVM crashes: one death produces two spans. The in-process
handler emits crash.type=jvm_exception with the full stack trace; the OS
post-mortem emits crash.type=jvm_crash with process-level facts (pss/rss,
importance, exit status) but no stack — Android only retains trace blobs
for ANR and native-crash exits. Look at the jvm_exception span for the
stack.


Errors

| What | How It Works |
|------|--------------|
| Flutter framework errors | Caught via FlutterError.onError (render errors, setState issues, etc.) |
| Uncaught async exceptions | Caught via PlatformDispatcher.onError |
| Manual error reports | Call ScoutFlutter.reportError(error, stackTrace) |

All errors are exported as spans with error.type, error.message, and error.stack_trace attributes.


Performance

| What | Span / Metric Name | Details |
|------|-------------------|---------|
| App startup time | app_startup | Cold start and warm start duration in milliseconds |
| Screen load time | screen_load | Time from navigation push to first frame rendered (requires navigator observer) |
| Long tasks (jank) | long_task | Detects when Dart main isolate is blocked beyond threshold (default: 100ms) |
| ANR (App Not Responding) | anr | Native watchdog thread detects unresponsive main thread (default: 5s threshold) |
| Frame build time | flutter.frame.build_time | Histogram of per-frame build durations. Opt-in via `enableFrameMetrics` (default off — records on every frame with one stream per screen, the highest-volume metrics the SDK can produce) |
| Frame raster time | flutter.frame.raster_time | Histogram of per-frame raster durations. Opt-in via `enableFrameMetrics` |
| Frozen frames | frozen_frame | Frames exceeding 700ms (always on, independent of `enableFrameMetrics`) |
| CPU usage | flutter.cpu.usage | CPU percentage gauge, polled every `vitalsCollectionIntervalSeconds` (default 60). Disable via `enableCpuMetrics` |
| Memory usage | flutter.memory.usage | Native memory gauge, polled every `vitalsCollectionIntervalSeconds` (default 60). Disable via `enableMemoryMetrics` |

Metrics are exported in batches every `metricExportIntervalSeconds` (default 60).


User Interactions

| What | Span Name | Details |
|------|-----------|---------|
| Taps | user_interaction | Auto-detected on Buttons, GestureDetectors, InkWells, Switches, Tabs. Includes widget label. |
| Screen views | screen_view | Tracked when routes change (requires navigator observer) |
| View sessions | view_session | Time spent on each screen (requires navigator observer) |
| App lifecycle | app_paused, app_resumed | Background/foreground transitions |


Network

| What | Span Name | Details |
|------|-----------|---------|
| HTTP requests | http.request | Method, URL, status code, duration, response size. Auto-tracked for dart:io HttpClient and Dio. |
| Distributed tracing | — | W3C traceparent header injected on requests to first-party hosts |


Logs

| What | Details |
|------|---------|
| Structured logs | Exported via OTLP with severity levels (debug, info, warning, error) |
| Print capture | Optional — capture debugPrint() output as info-level logs |


Device Context

Attached as resource attributes to all telemetry:
- Device model, manufacturer, OS version
- App version
- Battery level
- Network connectivity type (wifi, cellular, etc.)
- Custom attributes you set


────────────────────────────────────────────────


CUSTOM INSTRUMENTATION

Log events

ScoutFlutter.logEvent('purchase_completed', attributes: {
  'item_id': 'SKU-123',
  'amount': '49.99',
});


Add breadcrumbs

Breadcrumbs are attached to crash reports so you can see what the user did before a crash:

ScoutFlutter.addBreadcrumb('checkout', 'added item to cart');
ScoutFlutter.addBreadcrumb('checkout', 'entered payment details');


Report errors manually

try {
  await riskyOperation();
} catch (e, stackTrace) {
  ScoutFlutter.reportError(e, stackTrace);
}


Set user identity

Attached to all subsequent spans and logs:

ScoutFlutter.setUser(id: 'user-456', email: 'jane@example.com');


Structured logging

ScoutFlutter.logDebug('Cache hit for product list');
ScoutFlutter.logInfo('User completed onboarding');
ScoutFlutter.logWarning('Retry attempt 2 for payment API');
ScoutFlutter.logError('Payment gateway timeout', error: e, stackTrace: st);


Annotate widgets

For custom tap labels on widgets the SDK can't auto-label:

RumUserActionAnnotation(
  description: 'Add to cart',
  child: MyCustomWidget(),
)


────────────────────────────────────────────────


CONFIGURATION REFERENCE

ScoutFlutterConfig(
  // Required
  serviceName: 'my-app',
  endpoint: 'https://otel.your-domain.com:4318',

  // App identity
  serviceVersion: '1.0.0',
  environment: 'production',
  secure: true,                              // Use HTTPS (default: true)
  headers: {'Authorization': 'Bearer ...'},  // OTLP export headers

  // Feature toggles (all default to true)
  enableAutoTapTracking: true,
  enableErrorTracking: true,
  enableLifecycleTracking: true,
  enableStartupTracking: true,
  enableConnectivityTracking: true,
  enablePerformanceMetrics: true,
  enableLongTaskDetection: true,
  enableAnrDetection: true,
  enableNetworkTracking: true,
  enableLogging: true,

  // Per-metric switches
  enableFrameMetrics: false,                 // Per-frame histograms (default: off — very high volume)
  enableMemoryMetrics: true,                 // flutter.memory.usage gauge
  enableCpuMetrics: true,                    // flutter.cpu.usage gauge

  // Metric cadence
  metricExportIntervalSeconds: 60,           // Export batch interval (min: 1)
  vitalsCollectionIntervalSeconds: 60,       // Memory/CPU poll interval (min: 1)

  // Thresholds
  longTaskThresholdMs: 100,                  // Min: 20ms
  anrThresholdMs: 5000,                      // Min: 1000ms

  // Sessions — the sampling decision is made once per session and
  // applies to ALL signals: spans, metrics, and logs. An unsampled
  // session sends nothing (errors/crashes bypass by default).
  sessionSampleRate: 100.0,                  // 0.0 to 100.0
  sessionTimeoutMinutes: 30,                 // Rotate after inactivity

  // Network
  firstPartyHosts: ['api.example.com'],      // Receive traceparent headers
  ignoreUrlPatterns: [RegExp(r'/health')],   // Exclude from tracking

  // Logging
  capturePrintStatements: false,             // Capture debugPrint() as logs

  // Storage
  maxOfflineStorageMb: 5,                    // Offline queue cap

  // Filtering
  beforeSend: (event) {
    // Drop health check spans
    if (event['http.url']?.toString().contains('/health') == true) {
      return null; // Drop this event
    }
    // Scrub PII
    event.remove('enduser.email');
    return event; // Send modified event
  },

  // Custom resource attributes
  resourceAttributes: {
    'deployment.region': 'us-east-1',
    'team': 'mobile',
  },
)


────────────────────────────────────────────────


EVENT FILTERING

Use beforeSend to drop or modify events before they're exported:

- Return the event map to send it (modified or as-is)
- Return null to drop it entirely
- The event map includes a 'type' field: "span", "metric", or "log"

Examples:

// Drop all events from a specific screen
beforeSend: (event) {
  if (event['screen.name'] == 'DebugScreen') return null;
  return event;
}

// Only send error and crash events in low-bandwidth mode
beforeSend: (event) {
  final type = event['type'];
  final name = event['name'] ?? '';
  if (name.contains('crash') || name.contains('error')) return event;
  return null;
}


────────────────────────────────────────────────


PLATFORM SUPPORT

| Feature | Android | iOS |
|---------|---------|-----|
| Tap tracking | Yes | Yes |
| Lifecycle tracking | Yes | Yes |
| Error tracking | Yes | Yes |
| Navigation tracking | Yes | Yes |
| App startup time | Yes | Yes |
| Long task detection | Yes | Yes |
| ANR detection | Yes | Yes |
| Frame metrics | Yes | Yes |
| CPU / Memory | Yes | Yes |
| HTTP tracking | Yes | Yes |
| Structured logging | Yes | Yes |
| Session marker crashes | Yes | Yes |
| JVM / NSException crashes | Yes | Yes |
| Native signal crashes (SIGSEGV, etc.) | Yes | Yes |


────────────────────────────────────────────────


DATA PIPELINE

Scout Flutter exports all telemetry via OpenTelemetry Protocol (OTLP) over HTTP:

App → OTLP Collector → Base14 Backend → Dashboard

- Traces: Spans for interactions, navigation, crashes, errors, HTTP requests
- Metrics: Histograms and gauges for frame times, memory, CPU
- Logs: Structured log records with severity levels

Failed exports are queued to local storage and retried automatically when connectivity returns.


────────────────────────────────────────────────


DASHBOARD

[Screenshot: RUM Dashboard Overview]

The RUM dashboard provides:

- Crash-free session rate and total crash/error counts
- Crash trends over time broken down by crash type
- Error trends over time broken down by error type
- App startup performance (average and p95)
- Screen load times per screen
- Long task and ANR frequency
- HTTP request duration (average and p95)
- CPU and memory usage over time
- Top screens with load time breakdown
- Recent crash details with stack traces

[Screenshot: Crash Report Detail]


────────────────────────────────────────────────


SDK SAFETY

The SDK is designed to never crash your app. Every telemetry callback, error handler, and export path is wrapped in try/catch. If any telemetry operation fails, it silently degrades — your app continues running normally.
