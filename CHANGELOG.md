## 0.1.19

### Features
- `ScoutFlutter.setSessionAttributes(Map<String, Object>)` adds session-scoped attributes that ride on every subsequent span, metric, and log for the rest of the session. Keys pass through verbatim (no auto-prefix, unlike `setUser` which forces `user.*`). Replaces the previous map; clear with `ScoutFlutter.clearSessionAttributes()`. Use for feature flags, tenant IDs, experiment buckets, build channel — anything the consumer wants correlated across all signals in a session without abusing the `user.*` namespace. Merged into `_commonAttributes` so it also lands on `app_crash` spans drained from a previous session's marker and on every log emission.
- `device.is_jail_broken` resource attribute (`"true"` / `"false"` string) now ships on every span, metric, and log. Sourced at SDK init via a new `isDeviceCompromised` platform-channel call. iOS detection mirrors KSCrash's documented approach: filesystem-existence checks for standard jailbreak markers (`/Applications/Cydia.app`, `/Library/MobileSubstrate/MobileSubstrate.dylib`, `/etc/apt`, Sileo, Zebra, sshd, sftp-server, bash), a `DYLD_INSERT_LIBRARIES` env-var check (the standard tweak-injection vector), and a sandbox-escape write probe to `/private/`. Always returns `false` on iOS simulator (compile-time gated via `targetEnvironment(simulator)`). Android detection mirrors Sentry's `RootChecker` approach: `Build.TAGS` "test-keys" probe, common su / Magisk file paths (`/system/bin/su`, `/system/xbin/su`, `/sbin/.magisk`, `/system/app/Superuser.apk`, and 9 more), a `Runtime.exec("/system/xbin/which su")` probe to catch su binaries not at the standard paths, and a `PackageManager.getPackageInfo()` probe across known root-cloaker and superuser apps (Magisk, SuperSU, koush superuser, RootCloak, etc.). Resource attribute means downstream queries can correlate compromise state with any signal — previously this was iOS-only and only appeared as `crash.jailbroken` on `native_crash` spans drained from KSCrash. Known limitation: dedicated cloakers (Magisk Hide / DenyList on Android, app-targeted jailbreak tweaks on iOS) can defeat heuristic detection; raw-syscall bypass of function hooks (KSCrash's stronger anti-anti-detection technique) is intentionally not implemented — telemetry threat model does not require it

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
