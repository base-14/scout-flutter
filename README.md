# Scout Flutter

[![pub package](https://img.shields.io/pub/v/scout_flutter.svg)](https://pub.dev/packages/scout_flutter)
[![publisher](https://img.shields.io/pub/publisher/scout_flutter.svg)](https://pub.dev/publishers/base14.io)

Zero-config OpenTelemetry RUM (Real User Monitoring) for Flutter. One package, one `initialize()` call — and the SDK captures spans, metrics, and logs for taps, navigation, errors, lifecycle, crashes, performance, and network out of the box.

- **Package** — https://pub.dev/packages/scout_flutter
- **Publisher** — [base14.io](https://pub.dev/publishers/base14.io)

## What's Captured

### Auto-captured (zero code changes)

| Signal | Span/Metric | Details |
|--------|-------------|---------|
| Taps | `user_interaction` | Buttons, GestureDetectors, InkWells, Switches, Tabs |
| Lifecycle | `app_paused`, `app_resumed` | Background/foreground transitions |
| Errors | `error.count` metric | FlutterError + uncaught async exceptions |
| Device info | Resource attributes | Model, manufacturer, battery level, battery discharge rate, orientation, connectivity |
| App startup | `app_startup` | Cold start and warm start duration |
| Long tasks | `long_task` | Main isolate jank detection (configurable threshold) |
| ANR | `anr` | Native watchdog detects unresponsive main thread; captures full thread dump and breadcrumbs |
| Frame metrics | `flutter.frame.build_time`, `flutter.frame.raster_time` | Per-frame build and raster histograms — opt-in via `enableFrameMetrics` (default off; records every frame, one stream per screen) |
| Frozen frames | `frozen_frame` | Frames exceeding 700ms |
| Memory | `flutter.memory.usage` | Periodic native memory gauge (`vitalsCollectionIntervalSeconds`, default 60s; disable via `enableMemoryMetrics`) |
| CPU | `flutter.cpu.usage` | Periodic CPU usage percentage gauge (disable via `enableCpuMetrics`) |
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

Three categories of crashes:

- **Session marker** (`app_crash`) — OOM kills, `exit()` calls, and SIGKILL via persistent marker file. Reported on the next launch with the crashed session's breadcrumbs.
- **JVM / NSException** (`native_crash`) — uncaught Java/Kotlin exceptions on Android, NSExceptions on iOS. Written to disk before the process dies.
- **Native signals** (`native_crash`) — SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP. On Android, an in-process C signal handler captures stack trace via frame-pointer walk, register dump, signal code, pid/tid/uid, memory map, ABI, build fingerprint, kernel version, process uptime. On iOS, the native crash reporter captures POSIX signals, Mach exceptions, C++ exceptions, and main-thread deadlock, with MetricKit supplying OS-delivered crash/hang diagnostics.

Breadcrumbs are persisted to disk on every record, so they survive crashes and ship with both `app_crash` and `native_crash` spans.

Android `ApplicationExitInfo` post-mortems are filtered to crash-class reasons only (`anr`, `jvm_crash`, `native_crash`, `low_memory`) — normal exits like the user swiping the app away are never reported as crashes — and each record is reported exactly once via a persisted drain watermark. A JVM death produces two spans: `jvm_exception` (in-process, full stack trace) and `jvm_crash` (OS post-mortem, process facts, no stack — Android retains trace blobs only for ANR/native-crash exits).

## SDK Crash Safety

Every telemetry callback, error handler, and export path is wrapped in `try/catch`. If any telemetry operation fails, it silently degrades — your app continues running normally.

## Sampling

By default Scout samples **1% of sessions** (`sessionSampleRate: 1.0`). The decision is made once per session and applies uniformly to **all three signals — spans, metrics, and logs**: a sampled session sends everything (coherent traces, matching metrics and logs); an unsampled session sends nothing.

Error- and crash-class spans (`error`, `native_crash`, `app_crash`, `anr`, `ui_hang`) and error-level logs bypass the session sample rate by default. Set `alwaysCaptureErrors: false` to subject them to the same gate. Sampling is enforced both at the OpenTelemetry layer (so it also covers direct `tracer.startSpan` calls) and in a single fail-closed gate shared by every emit path — telemetry produced before the session exists is dropped, never leaked.

## Export cadence

- **Spans** — batched, exported every 5 s, single-attempt delivery (no retries, so a batch is never duplicated on the backend).
- **Metrics** — exported every `metricExportIntervalSeconds` (default 60). Memory/CPU are polled every `vitalsCollectionIntervalSeconds` (default 60).
- **Logs** — exported per entry; failed exports are queued offline and replayed.

## Debug Logging

Set `debugLogging: true` to print a `[scout]` line for every init, session rotation, sampling decision, export batch, and log entry. Useful while integrating; noisy in production.

```
[scout] init ok (service=my-app endpoint=http://localhost:4318 v=1.0.0 sampleRate=1.0 alwaysCaptureErrors=true)
[scout] session a1b2c3 sampled=true
[scout] span screen_view → recordAndSample
[scout] span http.request → drop
[scout] export batch: 8 spans (212ms) ok
[scout] log [warn] Retry attempt 2
```

## Public API surface

- `ScoutFlutter.initialize(config: ...)` — boot the SDK
- `ScoutFlutter.navigatorObserver` — navigation/screen tracking
- `ScoutFlutter.dioInterceptor` — Dio HTTP interceptor (apps using `dart:io` HttpClient are tracked automatically)
- `ScoutFlutter.observeScroll(child: ...)` — scroll-depth instrumentation
- `ScoutFlutter.logEvent(name, attributes: ...)` — custom business events
- `ScoutFlutter.logInfo/logWarning/logError/logDebug(...)` — structured logging
- `ScoutFlutter.addBreadcrumb(type, message)` — error context
- `ScoutFlutter.reportError(error, stackTrace)` — manual error reporting
- `ScoutFlutter.setUser(id: ..., attributes: ...)` / `clearUser()` — user identity
- `ScoutFlutter.setSessionAttributes({...})` / `clearSessionAttributes()` — session-scoped attributes
- `RumUserActionAnnotation` — custom tap labels for non-standard widgets
- `headers` config — OTLP auth headers sent with every export (e.g. `Authorization: Bearer …`)
- `beforeSend` config — filter or modify events before export
- `maxTombstoneBytes` config — cap on Android exit-info tombstone bytes captured for ANR/native post-mortems
- `enableFrameMetrics` config — opt into per-frame build/raster histograms (default off; highest-volume metrics)
- `enableMemoryMetrics` / `enableCpuMetrics` config — toggle the periodic vitals gauges individually
- `metricExportIntervalSeconds` config — metric export batch interval (default 60)
- `vitalsCollectionIntervalSeconds` config — memory/CPU poll interval (default 60)

## Architecture

Telemetry is exported via OpenTelemetry Protocol (OTLP) over HTTP:
- **Traces** — spans for user interactions, navigation, crashes, HTTP requests
- **Metrics** — histograms and gauges for frame times, memory, CPU
- **Logs** — structured log records with severity levels

Data flows through a `beforeSend` filter, then to the OTLP collector. Failed exports are queued offline and retried when connectivity returns.

## Platform Support

| Platform | Taps | Lifecycle | Errors | Navigation | Crashes | ANR | Native Vitals |
|----------|------|-----------|--------|------------|---------|-----|---------------|
| Android  | Yes  | Yes       | Yes    | Yes        | Yes     | Yes | Yes           |
| iOS      | Yes  | Yes       | Yes    | Yes        | Yes     | Yes | Yes           |

Both platforms capture native crashes in-process. iOS covers POSIX signals (SIGSEGV/SIGABRT/…), Mach exceptions, C++ exceptions, NSException, and main-thread deadlock, complemented by MetricKit for OS-delivered crash and hang diagnostics. Android pairs an in-process C signal handler with `ApplicationExitInfo` post-mortems.

## License

MIT
