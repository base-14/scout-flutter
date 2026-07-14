## 0.1.23

### Changed — minimal-telemetry defaults
- **`enableMemoryMetrics` and `enableCpuMetrics` now default to `false`.** With `enableFrameMetrics` already off, the SDK ships **no metrics by default** — vitals gauges are opt-in per app.
- **Offline buffering is now fully disabled by default**: `offlineBufferEnabled: false` and `offlineMaxTraceItems` / `offlineMaxMetricItems` / `offlineMaxLogItems` all `0`. Nothing is stored on disk; a failed export is dropped (strict at-most-once). Set `offlineBufferEnabled: true` plus per-signal caps to restore the old durability behavior.

### Added — unified batch/export config (applies to spans, metrics, AND logs)
- `exportIntervalSeconds` (default 30, min 1) — one export cadence for all three signals. Spans previously batched on a hardcoded 5 s schedule; metrics on 60 s; logs not at all.
- `maxExportBatchSize` (default 512, min 1) — max items per export batch.
- `maxQueueSize` (default 2048, min 1) — max items buffered awaiting export; overflow is dropped.
- `maxRetries` (default 0, min 0) — delivery attempts after failure, now applied to the span, metric, **and log** exporters. Logs previously retried up to 3× on ambiguous failures and could be delivered twice; they are now at-most-once like spans.
- `metricExportIntervalSeconds` is now a nullable **metrics-specific override** — unset (default) means metrics follow `exportIntervalSeconds`.

### Added — log batching
- Logs are now batched like spans and metrics via a new internal batcher: buffered up to `maxQueueSize`, flushed every `exportIntervalSeconds` or as soon as `maxExportBatchSize` records accumulate, and force-flushed when the app is backgrounded. Previously **every log entry was its own HTTP POST**.

### Fixed
- The InstrumentationScope version on every span/metric/log now matches the package version (it had been stuck at `0.1.5` since that release, making SDK-version adoption invisible to backends). A guard test fails CI if `scope.dart` and `pubspec.yaml` ever drift again.

## 0.1.22

### Fixed
- **Duplicate spans (same span ID) eliminated.** The upstream OTLP HTTP span exporter retried failed batches up to 3 times, including on ambiguous outcomes (response timeout, connection reset, 429/503) where the collector had often already ingested the batch — so identical spans were delivered again and the backend stored 2–4 copies with the same span ID. Span export is now single-attempt (`maxRetries: 0`, at-most-once): a batch that fails transiently is dropped instead of risking duplicates.
- **Session sampling no longer leaks startup telemetry.** The `SessionManager` was created *after* the long-task detector, frame metrics, cold-start measurement, and the tracer — and every sampling gate defaulted open (`?? true`) while it was null, so everything emitted during that window (`long_task` spans from startup jank especially) bypassed `sessionSampleRate` entirely. The session manager is now constructed and hydrated before the tracer and all detectors, and every gate fails closed: no session decision means drop, never leak. Error-class spans and error-level logs still bypass via `alwaysCaptureErrors`, even before the session exists, so crashes during initialization are never lost.
- Sampling is now enforced through a single `ScoutSampleGate` shared by every span, metric, and log emit path (previously six scattered inline checks), so the per-session decision uniformly covers all three signals.
- **Android exit-info crash reports were re-emitted on every launch.** `ApplicationExitInfo` history (up to 16 records, retained by the OS for days) is not consumed on read, and no drain watermark was persisted — so every app start re-reported the same historical deaths as fresh `native_crash` spans, inflating crash counts multiplicatively. The SDK now persists the highest drained `crash_death_timestamp_ms` and emits each exit record exactly once.
- **Benign Android exits were reported as crashes.** Every `ApplicationExitInfo` reason shipped as a `native_crash` span — including `user_requested` (user swiped the app from recents or closed the ANR dialog), `user_stopped` (Force Stop), and `exit_self` (normal `exit()`). Only crash-class reasons (`anr`, `jvm_crash`, `native_crash`, `low_memory`) are emitted now. Note: `jvm_crash` exit-info spans inherently carry no stack trace (the OS retains traces only for ANR/native-crash exits) — the full stack for the same death arrives on the companion `jvm_exception` span from the in-process handler.
- **Android ANR detection was phase-dependent and missed most hangs barely over the threshold.** The watchdog posted a main-thread ping and then slept for the full threshold before checking, so a hang was only detected if the ping happened to land inside it — a 6 s hang against the default 5 s threshold was missed ~80 % of the time (the OS would show its ANR dialog while Scout recorded nothing). The watchdog now polls every 100 ms and measures how long the ping has been unanswered, detecting any hang ≥ threshold + ~0.6 s deterministically. Single-fire per hang and re-arm-on-recovery semantics are preserved; the callback still runs on the watchdog thread mid-hang so the live thread dump captures the wedged main-thread stack. Covered by new JVM unit tests (`AnrWatchdogTest`) via an injectable ping poster. iOS is unaffected — its `AppHangWatchdog` already polled at fine granularity.
- **Infinite log loop when `debugLogging` and `capturePrintStatements` were both enabled.** The print-capture hook re-ingested the SDK's own `[scout]` diagnostic lines, each captured log printed another `[scout] log [...]` line, and the cycle looped forever — flooding the console and the log exporter. SDK-prefixed messages are now excluded from print capture.

### Changed
- **Metric export interval: 1 s → 60 s default** (`metricExportIntervalSeconds`, min 1). The SDK previously inherited flutterrific's 1-second `PeriodicExportingMetricReader` — with cumulative temporality every metric stream (one per screen visited, per instrument) re-exported every second for the life of the process, which multiplied fleet-wide into billions of points/day. One export per minute cuts that 60×.
- **Native vitals poll: 500 ms → 60 s default** (`vitalsCollectionIntervalSeconds`, min 1). Memory/CPU gauges are last-value; polling faster than the export interval produced values that were never exported, at the cost of 4 platform-channel calls/second.
- **`flutter.frame.build_time` and `flutter.frame.raster_time` are now opt-in** (`enableFrameMetrics`, default `false`). They record on every rendered frame with one stream per screen — by far the highest-volume metrics the SDK produced. When frame metrics are disabled, the upstream flutterrific `flutter.frame.duration` (also recorded per frame) is dropped at the exporter as well. Frozen-frame detection (the `frozen_frame` span) is unaffected and stays on.
- **`flutter.lifecycle.state_change` is no longer exported.** It is emitted by the underlying flutterrific layer (not Scout), is fully redundant with the `app_paused`/`app_resumed` spans, and its cumulative streams re-exported on every batch forever. `FixedHttpMetricExporter` now drops it before the payload leaves the device.

### Added
- `enableMemoryMetrics` / `enableCpuMetrics` config switches (default `true`) — disable either gauge individually; when disabled the corresponding native platform-channel poll is skipped entirely.

## 0.1.21

### Changed
- Upgraded `battery_plus` (^6 → ^7), `connectivity_plus` (^6 → ^7), and `device_info_plus` (^11 → ^12) to their latest majors. No API or behaviour change in Scout — the captured resource attributes (`device.battery.*`, `device.model.*`, `device.manufacturer`, `network.connection.type`, etc.) are identical, and `device_info_plus` 12's only removal (`AndroidDeviceInfo.serialNumber`) is unused. **Consuming apps must build with Android Gradle Plugin ≥ 8.12.1, Gradle ≥ 8.13, and Kotlin 2.2.0** — the minimum Android toolchain these plugin majors require. No change to Scout's minimum Flutter (3.29) / Dart (3.7) or Android `minSdk` (21).

## 0.1.20

### Features
- Live ANR thread dump on the `anr` span — `anr.main_thread_stack` (the blocked main-thread stack), `anr.threads_json`, and `anr.thread_count`. Android captures every managed thread (name, state, priority, daemon, frames) via `Thread.getAllStackTraces()` from the watchdog thread while the main thread is wedged; iOS captures the hung main thread's backtrace by suspending its Mach thread, reading the registers, walking the frame-pointer chain, and symbolicating via `dladdr`. Each thread-dump JSON is capped at 32 KB. Lets a backend show exactly what the main thread was blocked on at the moment a freeze was detected — without waiting for the process to die.
- Breadcrumbs now ride the live `anr` span (`breadcrumbs` attribute, the last 20 recorded actions), matching `error` and `native_crash` spans, so an ANR shows the tap/navigation/lifecycle trail leading into the freeze. Intentionally not attached to the high-frequency `ui_hang`/`long_task` spans to keep their payload small.
- `device.orientation` resource attribute (`portrait` / `landscape`) on every span, metric, and log. Derived from the platform view's physical size and refreshed on rotation via a metrics observer.
- `device.battery.discharge_rate` resource attribute on Android (instantaneous current draw in microamps from `BatteryManager.BATTERY_PROPERTY_CURRENT_NOW`). Omitted on iOS, which exposes no equivalent.
- `maxTombstoneBytes` config option (default 131072, minimum 4096) controls how many bytes of the native ANR / crash tombstone — the OS all-thread dump with lock-ownership graph drained from `ApplicationExitInfo` — are read and shipped as `crash.tombstone` on the `native_crash` span. Raise it for thread-heavy apps whose tombstones exceed 128 KB; the OS trace is read up to the cap and truncated beyond it.

### Fixed
- Android ANR watchdog now fires once per hang and re-arms only after the main thread recovers, instead of firing on every threshold window. A sustained freeze previously emitted 2–3 duplicate `anr` spans (one per 5 s window), inflating occurrence counts and re-shipping the thread dump; it now emits exactly one, matching the iOS hang watchdog's single-fire behaviour.
- iOS main-thread backtrace capture now reads the main thread's Mach port inside the `startAnrDetection` handler (which method-channel dispatch guarantees runs on the main thread) rather than at plugin construction, which could run on a background thread and leave `anr.main_thread_stack` empty.

## 0.1.19

### Features
- `ScoutFlutter.setSessionAttributes(Map<String, Object>)` adds session-scoped attributes that ride on every subsequent span, metric, and log for the rest of the session. Keys pass through verbatim (no auto-prefix, unlike `setUser` which forces `user.*`). Replaces the previous map; clear with `ScoutFlutter.clearSessionAttributes()`. Use for feature flags, tenant IDs, experiment buckets, build channel — anything the consumer wants correlated across all signals in a session without abusing the `user.*` namespace. Merged into `_commonAttributes` so it also lands on `app_crash` spans drained from a previous session's marker and on every log emission.
- `device.is_jail_broken` resource attribute (`"true"` / `"false"` string) now ships on every span, metric, and log. Sourced at SDK init via a new `isDeviceCompromised` platform-channel call. iOS detection uses filesystem-existence checks for standard jailbreak markers (`/Applications/Cydia.app`, `/Library/MobileSubstrate/MobileSubstrate.dylib`, `/etc/apt`, Sileo, Zebra, sshd, sftp-server, bash), a `DYLD_INSERT_LIBRARIES` env-var check (the standard tweak-injection vector), and a sandbox-escape write probe to `/private/`. Always returns `false` on iOS simulator (compile-time gated via `targetEnvironment(simulator)`). Android detection uses standard root-detection heuristics: `Build.TAGS` "test-keys" probe, common su / Magisk file paths (`/system/bin/su`, `/system/xbin/su`, `/sbin/.magisk`, `/system/app/Superuser.apk`, and 9 more), a `Runtime.exec("/system/xbin/which su")` probe to catch su binaries not at the standard paths, and a `PackageManager.getPackageInfo()` probe across known root-cloaker and superuser apps (Magisk, SuperSU, koush superuser, RootCloak, etc.). Resource attribute means downstream queries can correlate compromise state with any signal — previously this was iOS-only and only appeared as `crash.jailbroken` on `native_crash` spans drained from the native crash reporter. Known limitation: dedicated cloakers (Magisk Hide / DenyList on Android, app-targeted jailbreak tweaks on iOS) can defeat heuristic detection; raw-syscall bypass of function hooks (a stronger anti-anti-detection technique) is intentionally not implemented — telemetry threat model does not require it

## 0.1.18

### Features
- Android NDK native-crash images now carry their ELF GNU build-id as `uuid` in `crash.binary_images_json`, enabling backend symbolication of `.so` frames (the analog of an iOS dSYM UUID). The signal handler stays async-signal-safe (it only captures each image's base + name); the build-id is recovered at report-assembly time on a normal thread by resolving the image name against the app's `nativeLibraryDir` and reading `NT_GNU_BUILD_ID` from the on-disk library (`ElfBuildId`). Images that can't be resolved — system libraries, or libs not extracted to disk — are left without a `uuid` and their frames stay raw. iOS dSYM images already carry a per-image `uuid` (from KSCrash) and are unchanged

## 0.1.17

### Removed
- `simulateCrash` and `simulateAnr` removed from the SDK surface end-to-end: Dart wrapper (`ScoutPlatformChannel`), Android Kotlin method-channel handlers (`ScoutFlutterPlugin.kt`), the `nativeSimulateCrash` JNIEXPORT in `scout_crash_handler.c`, the matching `external fun nativeSimulateCrash()` declaration in `CrashReporter.kt`, and the iOS Swift cases in `ScoutFlutterPlugin.swift`. A production SDK should not ship crash-induction primitives — any host code (or another plugin sharing the binary messenger) could previously invoke `MethodChannel('com.base14.scout_flutter').invokeMethod('simulateCrash')` and kill the user's app, even without importing the now-removed Dart helpers. Test harnesses that need to exercise the crash-capture pipeline should implement their own platform-level null-deref / main-thread-block locally in the example app or test target; the SDK's capture path (KSCrash, JVM uncaught handler, NDK signal handler, MetricKit, ApplicationExitInfo) is unchanged and continues to ingest real crashes the same way

## 0.1.16

### Features
- `session.start_time` added as a span attribute on every emitted span. ISO 8601 UTC string sourced from `SessionManager.sessionStartTime`, which is persisted to `<docs>/scout_session.json` and rehydrated on resume — so the attribute remains consistent across process restarts within the same session, and rotates with `session.id`. On `app_crash` spans (which retain the crashed session's `session.id`), `session.start_time` is set to the crashed session's `startedAt` so the pairing is preserved

## 0.1.15

### Features
- HTTP attribute names migrated to stable OTel semantic conventions on `http.request` spans: `http.method` → `http.request.method`, `http.url` → `url.full`, `http.status_code` → `http.response.status_code`, `http.response_content_length` → `http.response.body.size`. `http.duration_ms` and `http.error` kept as scout extensions (no semconv equivalent). Backends that previously queried the legacy keys must update; coalescing with the old names is not provided
- `app.bundle_id`, `app.version`, `app.build` added as resource attributes on every signal — sourced from `package_info_plus` (iOS `CFBundleIdentifier` / Android `applicationId`, semver version, build number). Supports backend symbolication artifact matching (`(app_identifier, app_version, build_number, platform, arch)` tuple) without parsing the combined `service.version` string
- `dart.build_id` extracted from the Dart VM crash header and stamped on `error` spans when present. Populated only in AOT builds with `--split-debug-info` (debug builds have no build_id and the attribute is omitted). Lets the backend symbolizer match Dart `dart_symbols` artifacts via an indexed column instead of full-text trace parsing

### Build
- Swift Package Manager support — ships `ios/scout_flutter/Package.swift` with KSCrash declared as an SPM dependency (`KSCrashRecording` module). iOS Swift sources moved from `ios/Classes/` to `ios/scout_flutter/Sources/scout_flutter/`. Imports use conditional `#if canImport(KSCrash) … #else import KSCrashRecording #endif` so both CocoaPods and SPM consumers work. The Flutter SPM warning "scout_flutter does not support Swift Package Manager" no longer fires; verified via `flutter build ios` with SPM mode enabled (`flutter config --enable-swift-package-manager`)

## 0.1.14

### Features
- `session.id` now persists across process launches (including crashes). On init, `SessionManager` hydrates `<docs>/scout_session.json` and resumes the prior session if it's within `sessionTimeoutMinutes` of `lastActiveAt` and within `maxSessionDurationMinutes` of `startedAt` — otherwise mints a new session. Matches scout-react's storage-backed semantics. Crash spans (`app_crash`, `native_crash`) and post-relaunch telemetry now land on the same `session.id` as the pre-crash events, so a single "show events for session X" query returns the complete arc. Persisted state is `{v, id, startedAt, lastActiveAt, sampled}`; `sampled` is preserved so resumed sessions don't re-roll the sampling decision. Persistence fires on `start`, `rotateSession`, `onBackground`, and `onForeground` — not on every span, to keep write cost bounded.

## 0.1.13

### Features
- `device.locale` and `device.timezone` added as resource attributes on every span, metric, and log. Locale comes from `Platform.localeName` normalized to BCP-47 (e.g. `en-US`); timezone is the IANA identifier (e.g. `Asia/Kolkata`) sourced from a new `getTimezone` platform-channel method backed by `TimeZone.current.identifier` (iOS) and `TimeZone.getDefault().id` (Android). No permission prompt, no new packages, ships on every signal including `native_crash` and error spans
- `device.type` (`mobile` / `tablet`, derived from logical screen shortest-side) added as a resource attribute on every signal
- `device.name` populated from the real hardware identifier — iOS `utsname.machine` (e.g. `iPhone15,2`) on physical devices, Android `Build.MODEL` (e.g. `Pixel 8a`)
- `os.name` normalized to `iOS` / `Android` (replacing the lowercase `host.os.name`/`os.type` defaults)
- `os.version` now ships as a clean version string (iOS `systemVersion` e.g. `26.3.1`, Android `Build.VERSION.RELEASE` e.g. `14`) — previously the iOS value was the raw `"Version 26.3.1 (Build 23D8133)"` blob
- `os.build` added — iOS `kern.osversion` sysctl (e.g. `23D8133`), Android `Build.DISPLAY`
- `host.arch` now reports the real CPU architecture (`arm64` / `amd64` / `arm32` / `x86`) — iOS via compile-time arch check, Android via `Build.SUPPORTED_ABIS[0]` normalized. Fixes a dartastic-otel default that was setting `host.arch` to the hostname

## 0.1.12

### Fixes
- `service.version` now auto-detected from `PackageInfo` (pubspec `version` field) when `ScoutFlutterConfig.serviceVersion` is not set. Previously defaulted to a hardcoded `1.0.0`, masking the integrator's real app version on every span. Explicitly setting `serviceVersion` still wins. `ScoutFlutterConfig.serviceVersion` is now `String?`
- `AutoNameNavigatorObserver` no longer surfaces `Instance of 'CupertinoPage<dynamic>'` as the screen name for go_router (and any other declarative router whose `Page` subclass relies on the default `Object.toString()`). The observer now falls through to the subtree walk and reports the user-defined page widget's class name

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
