# Scout Flutter

Zero-config OpenTelemetry RUM (Real User Monitoring) for Flutter. Install the package, call `initialize()` — that's it.

## Quick Start

### 1. Add dependency

```yaml
dependencies:
  scout_flutter:
    git:
      url: https://github.com/base-14/scout_flutter.git
      ref: v0.1.1
```

### 2. Initialize in main()

```dart
import 'package:scout_flutter/scout_flutter.dart';

Future<void> main() async {
  await ScoutFlutter.initialize(
    config: ScoutFlutterConfig(
      serviceName: 'my-app',
      endpoint: 'https://your-otel-endpoint:4318',
    ),
  );
  runApp(const MyApp());
}
```

### 3. (Optional) Add navigation tracking

```dart
MaterialApp(
  navigatorObservers: [ScoutFlutter.navigatorObserver],
  // ...
)
```

That's it. Everything else is automatic.

## What's Captured

### Auto-captured (zero code changes)

| Signal | Span/Metric | Details |
|--------|-------------|---------|
| Taps | `user_interaction` | Buttons, GestureDetectors, InkWells, Switches, Tabs |
| Lifecycle | `app_paused`, `app_resumed` | Background/foreground transitions |
| Errors | `error.count` metric | FlutterError + uncaught async exceptions |
| Device info | Resource attributes | Model, manufacturer, battery level, connectivity |
| App startup | `app_startup` | Cold start and warm start duration |
| Long tasks | `long_task` | Main isolate jank detection (configurable threshold) |
| ANR | `anr` | Native watchdog thread detects unresponsive main thread |
| Frame metrics | `flutter.frame.build_time`, `flutter.frame.raster_time` | Per-frame build and raster histograms |
| Frozen frames | `frozen_frame` | Frames exceeding 700ms |
| Memory | `flutter.memory.usage` | Periodic native memory gauge |
| CPU | `flutter.cpu.usage` | Periodic CPU usage percentage gauge |
| Crash detection | `app_crash` | Detects OOM/SIGKILL/exit crashes via session marker |
| Native crashes | `native_crash` | JVM exceptions, NDK signals (SIGSEGV, SIGABRT, etc.) with full stack trace, registers, memory map |

### With navigator observer

| Signal | Span | Details |
|--------|------|---------|
| Screen views | `screen_view` | Auto-named from route settings or widget type |
| Screen load time | `screen_load` | Time from push to first frame rendered |
| View sessions | `view_session` | Time spent on each screen |

### With network tracking (enabled by default)

| Signal | Span | Details |
|--------|------|---------|
| HTTP requests | `http.request` | Method, URL, status, duration, response size |
| Distributed tracing | W3C `traceparent` | Injected for first-party hosts |

### Structured logging

| Signal | Export | Details |
|--------|--------|---------|
| Logs | OTLP logs | Debug, info, warning, error severity levels |
| Print capture | OTLP logs | Optional `debugPrint()` capture as info-level logs |

## Crash Detection

Scout detects three categories of crashes:

**Session marker crashes** (`app_crash` span) — Detects OOM kills, `exit()` calls, and SIGKILL by persisting a session marker file. If the app was in the foreground and never paused before terminating, the next launch emits a crash span with the previous session's breadcrumbs.

**JVM/NSException crashes** (`native_crash` span) — Catches uncaught JVM exceptions on Android and NSExceptions on iOS. Written to disk before the process dies and reported on next launch.

**Native signal crashes** (`native_crash` span) — Catches SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP on Android via a C signal handler. Captures:
- Full stack trace via frame pointer walk (not just signal handler frames)
- Register dump (PC, LR, SP, FP + general purpose registers)
- Signal code name (e.g. `SEGV_MAPERR`)
- Process/thread IDs and thread name
- Memory map (`/proc/self/maps`) for offline symbolication
- ABI, build fingerprint, kernel version, process uptime

**Breadcrumb persistence** — Breadcrumbs are written to disk on every record, so they survive crashes. Both `app_crash` and `native_crash` spans include the full breadcrumb trail from the crashed session.

## SDK Crash Safety

The SDK is designed to never crash your app. Every telemetry callback, error handler, and export path is wrapped in try/catch. If any telemetry operation fails, it silently degrades — your app continues running normally.

## Custom Events

```dart
// Log a business event
ScoutFlutter.logEvent('purchase', attributes: {'item': 'widget'});

// Add breadcrumb for error context
ScoutFlutter.addBreadcrumb('checkout', 'added item to cart');

// Report error manually
ScoutFlutter.reportError(error, stackTrace);

// Set user identity (attached to all subsequent spans)
ScoutFlutter.setUser(id: 'user-123', email: 'user@example.com');
```

## Structured Logging

```dart
ScoutFlutter.logDebug('Cache hit for product list');
ScoutFlutter.logInfo('User completed checkout');
ScoutFlutter.logWarning('Retry attempt 2 for API call');
ScoutFlutter.logError('Payment gateway timeout');
```

## Dio Support

For apps using Dio instead of `dart:io` HttpClient:

```dart
final dio = Dio();
dio.interceptors.add(ScoutFlutter.dioInterceptor);
```

## Annotate Widgets

For custom tap labels on widgets the SDK can't auto-label:

```dart
RumUserActionAnnotation(
  description: 'Add to cart',
  child: MyCustomWidget(),
)
```

## Event Filtering

Drop or modify events before export:

```dart
ScoutFlutterConfig(
  serviceName: 'my-app',
  endpoint: 'https://...',
  beforeSend: (event) {
    // Drop health check requests
    if (event['http.url']?.toString().contains('/health') == true) {
      return null;
    }
    // Scrub PII
    event.remove('enduser.email');
    return event;
  },
)
```

## Configuration

```dart
ScoutFlutterConfig(
  // Required
  serviceName: 'my-app',
  endpoint: 'https://your-otel-endpoint:4318',

  // App identity
  serviceVersion: '1.0.0',
  environment: 'production',
  secure: true,                          // HTTPS (default: true)
  headers: {'Authorization': 'Bearer ...'}, // OTLP export headers

  // Auto-instrumentation (all default to true)
  enableAutoTapTracking: true,
  enableErrorTracking: true,
  enableLifecycleTracking: true,
  enableStartupTracking: true,
  enableConnectivityTracking: true,
  enablePerformanceMetrics: true,        // FPS, memory, CPU, frame times
  enableLongTaskDetection: true,
  enableAnrDetection: true,
  enableNetworkTracking: true,           // HTTP request tracking
  enableLogging: true,                   // Structured log export

  // Thresholds
  longTaskThresholdMs: 100,              // Min 20ms
  anrThresholdMs: 5000,                  // Min 1000ms

  // Sessions
  sessionSampleRate: 100.0,             // 0.0-100.0 (default: 100)
  sessionTimeoutMinutes: 30,            // Rotate after inactivity

  // Network
  firstPartyHosts: ['api.example.com'], // Receive traceparent headers
  ignoreUrlPatterns: [RegExp(r'/health')],

  // Logging
  capturePrintStatements: false,        // Capture debugPrint() as logs

  // Storage
  maxOfflineStorageMb: 5,              // Offline queue cap

  // Filtering
  beforeSend: (event) => event,        // Modify/drop events

  // Custom
  resourceAttributes: {'deployment.region': 'us-east-1'},
  customGestureDetector: (widget) => null,
)
```

## Architecture

Scout Flutter exports telemetry via OpenTelemetry Protocol (OTLP) over HTTP:
- **Traces** — Spans for user interactions, navigation, crashes, HTTP requests
- **Metrics** — Histograms and gauges for frame times, memory, CPU
- **Logs** — Structured log records with severity levels

Data flows through a `beforeSend` filter, then to the OTLP collector. Failed exports are queued offline and retried when connectivity returns.

## Platform Support

| Platform | Taps | Lifecycle | Errors | Navigation | Crashes | ANR | Native Vitals |
|----------|------|-----------|--------|------------|---------|-----|---------------|
| Android  | Yes  | Yes       | Yes    | Yes        | Yes     | Yes | Yes           |
| iOS      | Yes  | Yes       | Yes    | Yes        | Partial | Yes | Yes           |

iOS crash detection covers session marker crashes and NSExceptions. Native signal handling (SIGSEGV etc.) is Android-only currently.

## License

MIT
