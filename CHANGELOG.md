## 0.1.8

### Fixes
- Warm start measurement no longer depends on the `onInactive` lifecycle callback; `_measureWarmStart()` starts its own stopwatch on resume

## 0.1.7

### Docs
- README rewritten to focus on capabilities; install/usage instructions moved to the integration guide
- Integration guide updated to install from pub.dev (was git URL)
- pub.dev publisher badge wired to base14.io

## 0.1.6

### Changes
- `sessionSampleRate` default changed from `100.0` to `1.0` (1% of sessions)
- New `alwaysCaptureErrors` flag (default `true`) — errors and crashes (`error`, `native_crash`, `app_crash`, `anr`, `ui_hang`) bypass `sessionSampleRate` and are always exported
- Sampling now enforced at the OpenTelemetry layer via a custom `Sampler`, so it also applies to spans from auto-instrumentation and direct `tracer.startSpan` calls
- New `debugLogging` flag (default `false`) — emits per-event `[scout]` diagnostics via `debugPrint` for init, session rotation, sampling decisions, export batches, and log entries

## 0.1.5

### Features
- iOS: deep crash reports via KSCrash, MetricKit, and ExitInfo
- UI hang detector for main-thread freezes
- FBC and INV vitals
- WebView bridge for capturing telemetry from embedded web content

## 0.1.4

### Changes
- All spans, metrics, and logs are now emitted under a single InstrumentationScope `base14.scout.flutter` (previously varied by signal type)

## 0.1.3

### Fixes
- Crash span now uses the crashed session's ID, not the new session
- Crash timestamp set to last known active time before crash
- Error details (type, message) extracted from breadcrumbs into crash span
- `error.handled` flag distinguishes framework-caught vs uncaught errors
- `last_active_at` persisted on every lifecycle status change for crash timing

## 0.1.2

### Changes
- `setUser` now accepts arbitrary attributes via `Map<String, Object>` instead of only `id` and `email`

## 0.1.1

### Fixes
- Bump CMake version to 3.18.1+ for AGP 8.9.1 compatibility (File API requirement)

## 0.1.0

### Crash Detection & SDK Hardening
- Three-layer crash detection: session marker (OOM/SIGKILL), native exception handlers (JVM/NSException), signal handlers (SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP)
- Native signal handler captures full crash context: stack trace via frame pointer walk, register dump, signal code, pid/tid/uid, memory map, ABI, build fingerprint, kernel version, process uptime
- Breadcrumb persistence to disk — breadcrumbs survive crashes and are included in crash spans
- Early error handler installation catches initialization failures
- SDK crash safety — all telemetry callbacks wrapped in try/catch, telemetry failure never crashes the host app
- Graceful fallback for unsupported CPU architectures in native crash handler
- Android: JVM uncaught exception handler + NDK signal handler via JNI
- iOS: NSException crash reporter

### Network, Sessions, Logging & Offline Queue
- HTTP request auto-tracking via `HttpOverrides` — method, URL, status, duration, response size
- Distributed tracing with W3C `traceparent` header injection for first-party hosts
- Dio interceptor for apps using Dio (`ScoutFlutter.dioInterceptor`)
- Session management with configurable sample rate and inactivity timeout
- Structured logging with OTLP export (debug, info, warning, error levels)
- Optional `debugPrint()` capture as info-level logs
- Offline queue for failed exports with configurable storage cap
- `beforeSend` callback for event filtering and modification
- Ignore URL patterns for network tracking

### Performance Monitoring
- Long task (jank) detection with configurable threshold
- Native ANR detection via platform-specific watchdog threads
- Cold start and warm start measurement
- Frame metrics: build time and raster time histograms
- Frozen frame detection (>700ms)
- Native memory and CPU usage gauges via platform channels
- View session tracking — time spent on each screen
- Screen load time measurement

### Core
- Auto tap detection via global pointer route (zero widget changes required)
- Auto lifecycle tracking (pause, resume, exit)
- Auto error tracking (FlutterError + uncaught errors)
- Optional navigation tracking via `ScoutFlutter.navigatorObserver`
- Device info and battery level collection
- Breadcrumb manager for error context
- Custom event logging via `ScoutFlutter.logEvent()`
- User identity tracking via `ScoutFlutter.setUser()`
- `RumUserActionAnnotation` widget for custom action labels
- OpenTelemetry export via `flutterrific_opentelemetry`
