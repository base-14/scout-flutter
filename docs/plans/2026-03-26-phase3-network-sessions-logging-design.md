# Phase 3 Design: Network, Sessions, Logging, Offline, Filtering

## Goal

Add HTTP/network tracking, distributed tracing, session management, structured logging, offline queueing, event filtering, and Dio interceptor to scout_flutter. All features auto-activate on `initialize()` — zero code changes beyond config.

## Decisions

| Feature | Approach | Rationale |
|---------|----------|-----------|
| HTTP tracking | `HttpOverrides.global` (like Datadog) | Auto-instruments all `dart:io` HttpClient users including `http` and Dio |
| Distributed tracing | W3C `traceparent` only | OTLP-native, vendor-neutral, industry standard |
| Session ID | Dart-side UUID v4 with inactivity timeout | Standard RUM pattern (Datadog, New Relic) |
| Session sampling | Drop-at-source | Saves battery, network, backend cost |
| Structured logging | OTLP `/v1/logs` protobuf export | Completes observability triad, single pipeline |
| Offline queueing | File-based queue in app temp dir | No new deps (no SQLite), survives app kill |
| Event filtering | Single `beforeSend` callback | Simple, like Coralogix |
| Dio support | Optional exported interceptor | Default Dio covered by HttpOverrides; interceptor for custom adapters |

## Architecture

### 1. HTTP/Network Tracking

- `ScoutHttpOverrides` set during `initialize()`, wraps any existing `HttpOverrides.current`
- `ScoutTrackingHttpClient` wraps every `HttpClient` created after init
- Creates a span per request with attributes:
  - `http.method`, `http.url`, `http.status_code`
  - `http.response_content_length`, `http.request_content_length`
  - `http.duration` (milliseconds)
  - `network.connection.type` (from existing connectivity tracking)
  - `session.id`, `screen.name`, `enduser.id` (auto-attached)
- Skips URLs matching `ignoreUrlPatterns` config
- Skips the SDK's own OTLP export endpoint (prevents recursive tracking)
- Config: `enableNetworkTracking` (default true), `ignoreUrlPatterns` (List<RegExp>?)

### 2. Distributed Tracing

- W3C `traceparent` header injected into outgoing requests
- Format: `00-{traceId}-{spanId}-01`
- Only injected for hosts matching `firstPartyHosts` config
- If `firstPartyHosts` is null/empty, no injection (safe default)
- Integrated into HttpOverrides tracking — same interception point
- Config: `firstPartyHosts` (List<String>?)

### 3. Session Management

- UUID v4 generated at `initialize()`, stored in memory
- Attached to every span, metric, and log as `session.id` attribute
- Inactivity timeout: session rotates after `sessionTimeoutMinutes` of background time (default 30)
- Lifecycle listener tracks foreground/background transitions
- On resume: if elapsed > timeout, generate new session ID + new sampling decision
- Public getter: `ScoutFlutter.sessionId`
- Config: `sessionTimeoutMinutes` (int, default 30)

### 4. Session Sampling

- At session start, roll random against `sessionSampleRate` (0.0-100.0, default 100.0)
- If sampled out: SDK initializes normally but all exporters become no-ops
- Sampling decision persists for entire session lifetime
- New session (cold start or inactivity rotation) = new sampling decision
- Config: `sessionSampleRate` (double, default 100.0)

### 5. Structured Logging

- Public API: `ScoutFlutter.log(LogLevel, message, {attributes})`
- Convenience: `.logDebug()`, `.logInfo()`, `.logWarning()`, `.logError()`
- Exports via OTLP HTTP `/v1/logs` using protobuf
- `FixedHttpLogExporter` — same pattern as `FixedHttpMetricExporter`
- Each log record includes: session ID, screen name, user context, severity, timestamp
- Print capture: optional `capturePrintStatements` config (default false)
  - Intercepts via Zone `print` override
  - Forwards as info-level logs
- Config: `enableLogging` (default true), `capturePrintStatements` (default false)

### 6. Offline Queueing

- File-based queue in app temp directory (`scout_offline/` subfolder)
- When export fails (network error or non-2xx): serialize batch as JSON-lines to timestamped file
- Flush strategy:
  - On connectivity change (already have connectivity listener)
  - Periodic timer (every 60s)
- Storage cap: `maxOfflineStorageMb` (default 5). Oldest files deleted when exceeded
- Applies to all three signals: spans, metrics, logs
- Implementation: `OfflineAwareExporter` decorator wraps each exporter, catches failures, queues to disk
- Config: `maxOfflineStorageMb` (int, default 5)

### 7. Event Filtering / Before-Send Hook

- `BeforeSendCallback? beforeSend` in config
- Signature: `Map<String, dynamic>? Function(Map<String, dynamic> event)`
- Event map includes `type` field: `"span"`, `"metric"`, or `"log"`
- Return map (possibly modified) to send, return `null` to drop
- Called in exporter layer before serialization
- Config: `beforeSend` (callback, optional)

### 8. Dio Interceptor (Optional Export)

- `ScoutDioInterceptor` class exported from package
- `onRequest`: stamp start time, inject traceparent if host in firstPartyHosts
- `onResponse`/`onError`: create span with HTTP attributes, duration
- Usage: `dio.interceptors.add(ScoutFlutter.dioInterceptor)`
- Only needed for custom Dio adapters; default Dio already covered by HttpOverrides

## New Config Fields

```dart
ScoutFlutterConfig(
  // ... existing fields ...

  // Network tracking
  enableNetworkTracking: true,           // default true
  ignoreUrlPatterns: null,               // List<RegExp>?, optional

  // Distributed tracing
  firstPartyHosts: null,                 // List<String>?, optional

  // Sessions
  sessionSampleRate: 100.0,             // 0.0-100.0, default 100.0
  sessionTimeoutMinutes: 30,            // default 30

  // Logging
  enableLogging: true,                   // default true
  capturePrintStatements: false,         // default false

  // Offline
  maxOfflineStorageMb: 5,               // default 5

  // Filtering
  beforeSend: null,                      // BeforeSendCallback?, optional
);
```

## Data Flow

```
App Code --> HttpOverrides/DioInterceptor --> Span/Log creation
                                                 |
                                           beforeSend hook
                                                 |
                                       Session sampling check
                                                 |
                                     OTLP Exporter (spans/metrics/logs)
                                                 |
                                       Success? --> Done
                                       Failure? --> Offline file queue
                                                 |
                                       Connectivity restored --> Flush queue
```

## New Files

- `lib/src/scout_http_overrides.dart` — HttpOverrides wrapper
- `lib/src/scout_tracking_http_client.dart` — Tracking HttpClient
- `lib/src/scout_dio_interceptor.dart` — Optional Dio interceptor
- `lib/src/session_manager.dart` — Session ID generation, rotation, sampling
- `lib/src/scout_logger.dart` — Log API and print capture
- `lib/src/fixed_http_log_exporter.dart` — OTLP log exporter
- `lib/src/offline_exporter.dart` — OfflineAwareExporter decorator
- `lib/src/offline_queue.dart` — File-based queue management

## Dependencies

No new package dependencies. Uses:
- `dart:io` for HttpOverrides (already available)
- `dart:math` for UUID generation (already used)
- `path_provider` — needed for app temp directory (already transitively available via flutter)
- Existing `connectivity_plus` for flush triggers
