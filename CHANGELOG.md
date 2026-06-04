## 0.1.11

### Breaking changes
- User identity is now emitted under the `user.*` namespace instead of `enduser.*`. `setUser(id: 'u1', attributes: {'email': '...', 'phone': '...'})` produces `user.id`, `user.email`, `user.phone`. The auto-attached anonymous identifier is now `user.anonymous_id`. Dashboards / queries that filter on `enduser.*` must move to `user.*`
- `setUser` no longer requires `id` — `setUser(attributes: {'tenant': 'acme'})` is valid. Bare attribute keys are auto-prefixed with `user.`; keys already starting with `user.` pass through unchanged

### Breadcrumbs on crash spans
- iOS `native_crash` spans now carry per-report `breadcrumbs` baked into `KSCrash.userInfo` at crash time, so the trail matches the crashed session — including delayed MetricKit reports and multi-crash drains
- Android `native_crash` spans now also carry breadcrumbs in the backgrounded-then-killed case: when `ApplicationExitInfo` surfaces a crash with no live in-process marker, `_drainCrashReports` consumes the on-disk `breadcrumbs.json` left over from the paused session
- Dart-side `addBreadcrumb` forwards every breadcrumb to the native side via a new `setBreadcrumbs` method channel (no-op on Android)
- `CrashDetector` no longer deletes `breadcrumbs.json` on the `paused` shutdown path

### Android `native_crash` — iOS-parity overhaul
- Existing scout_crash_handler `.so` is now actually exercised: `simulateCrash` routes through a new `nativeSimulateCrash` JNI export that derefs NULL so real signal-handler coverage is testable end-to-end
- C handler bugs fixed: `crash.timestamp` is ISO 8601 (was raw Unix); `crash.kernel_version` reads via `uname()` (was failing /proc/version on newer Android); process uptime computed via `CLOCK_BOOTTIME` (was failing /proc parse under SELinux)
- Android key names aligned to iOS: `crash.abi → crash.cpu_arch`, `crash.registers → crash.registers_json`, `crash.kernel → crash.kernel_version`. Integer `crash.signal_code` (raw `si_code`) plus string `crash.signal_code_name` both emitted
- New attributes on Android `native_crash`: `machine`, `device_model`, `os_name`, `os_version`, `os_build`, `app_uuid` (per-install UUID), `bundle_id`, `bundle_version`, `app_version`, `app_name`, `process_name`, `app_executable`, `executable_path`, `device_app_hash`, `idfv`, `build_type`, `environment`, `build_configuration`, `time_zone`, `system_boot_time_iso`, `app_start_time`, `translated`, `gid`, `signal` (string), `signal_number` (raw signum), `fault_address`, `exception_register`, `thread_count`, `thread_index`, `app_active`, `app_active_time_secs`, `app_background_time_secs`, `app_active_time_since_last_crash_secs`, `app_background_time_since_last_crash_secs`, `app_launches_since_last_crash`, `app_sessions_since_launch`, `app_sessions_since_last_crash`, `memory_free_bytes`, `memory_size_bytes`, `storage_size_bytes`, `storage_free_bytes`, `time_since_boot_secs`, `binary_images_json` (structured /proc/self/maps), `binary_images_count`, `report_id` (per-crash UUID), `report_type`, `report_version`, `parent_proc_name`, `parent_pid`
- Drain context attached at Dart-side drain time: `crash.drain_app_state`, `crash.drain_process_start_time`, `crash.drain_uptime_secs`

## 0.1.10

### Changes
- New `ScoutFlutterConfig.maxSessionDurationMinutes` (default 60, set 0 to disable) — caps total session lifetime; the next read of `sessionId` after the cap elapses rotates the session inline

## 0.1.9

### Changes
- iOS native crash reports now capture full device, OS, memory, app-state, and process context (sysctl-derived parent process, IDFV, boot time, foreground state at drain time)
- Crashed-thread registers expose FAR / ESR / exception registers as flat attrs; full per-thread callstack tree and binary images are no longer truncated
- KSCrash monitors expanded to include `userReported`, `system`, and `applicationState`
- Previous session's breadcrumbs are attached to the `native_crash` span via a `breadcrumbs` attribute
- Crash attribute forwarding switched to a generic `crash_*` → `crash.*` pass-through so new native fields surface without Dart changes
- Dropped Dart-side stack-trace truncation and the `error.was_truncated` flag

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
