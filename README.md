# Scout Flutter

[![pub package](https://img.shields.io/pub/v/scout_flutter.svg)](https://pub.dev/packages/scout_flutter)
[![publisher](https://img.shields.io/pub/publisher/scout_flutter.svg)](https://pub.dev/publishers/base14.io)

Zero-config OpenTelemetry RUM (Real User Monitoring) for Flutter. One package, one `initialize()` call — and the SDK captures spans, metrics, and logs for taps, navigation, errors, lifecycle, crashes, performance, and network out of the box.

- **Package** — https://pub.dev/packages/scout_flutter
- **Integration guide** — [doc/scout-flutter-guide.md](doc/scout-flutter-guide.md)
- **Publisher** — [base14.io](https://pub.dev/publishers/base14.io)

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

Three categories of crashes:

- **Session marker** (`app_crash`) — OOM kills, `exit()` calls, and SIGKILL via persistent marker file. Reported on the next launch with the crashed session's breadcrumbs.
- **JVM / NSException** (`native_crash`) — uncaught Java/Kotlin exceptions on Android, NSExceptions on iOS. Written to disk before the process dies.
- **Native signals** (`native_crash`) — SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP on Android via a C signal handler. Captures stack trace via frame-pointer walk, register dump, signal code, pid/tid/uid, memory map, ABI, build fingerprint, kernel version, process uptime.

Breadcrumbs are persisted to disk on every record, so they survive crashes and ship with both `app_crash` and `native_crash` spans.

## SDK Crash Safety

Every telemetry callback, error handler, and export path is wrapped in `try/catch`. If any telemetry operation fails, it silently degrades — your app continues running normally.

## Sampling

By default Scout samples **1% of sessions** (`sessionSampleRate: 1.0`). When a session is sampled, every span in it is recorded; otherwise the whole session is dropped, so session traces stay coherent.

Error- and crash-class spans (`error`, `native_crash`, `app_crash`, `anr`, `ui_hang`) bypass the session sample rate by default. Set `alwaysCaptureErrors: false` to subject them to the same gate. Sampling is enforced at the OpenTelemetry layer, so it also applies to spans emitted by auto-instrumentation and direct `tracer.startSpan` calls.

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
- `RumUserActionAnnotation` — custom tap labels for non-standard widgets
- `beforeSend` config — filter or modify events before export

See the [integration guide](doc/scout-flutter-guide.md) for full configuration reference and usage examples.

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
| iOS      | Yes  | Yes       | Yes    | Yes        | Partial | Yes | Yes           |

iOS crash detection covers session marker crashes and NSExceptions. Native signal handling (SIGSEGV etc.) is Android-only currently.

## License

MIT
