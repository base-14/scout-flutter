# Phase 2: View Sessions, App Startup, and Performance Vitals

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add view time tracking, cold/warm startup measurement, and OTel metrics for FPS, memory, CPU, frame build/raster times, and frozen frames.

**Architecture:** Spans for discrete events (view_session, app_startup, frozen_frame). OTel metrics via `FlutterOTel.meter()` for continuous vitals (FPS gauge, memory gauge, CPU gauge, build/raster histograms). Native platform channels for memory and CPU data. All tagged with `screen.name` for correlation. Enable `enableMetrics: true` in FlutterOTel.

**Tech Stack:** Flutter, flutterrific_opentelemetry (meters/gauges/histograms), SchedulerBinding.addTimingsCallback (frame timings), native Kotlin/Swift for memory/CPU, connectivity_plus for network type.

**Deferred to Phase 3:** Crash reporting (next-launch) using KSCrash (iOS) + NDK crash handler (Android) for native signal handling and disk persistence.

---

### Task 1: Enable OTel Metrics Pipeline

**Files:**
- Modify: `lib/src/scout_rum.dart:109` — change `enableMetrics: false` to `true`
- Modify: `lib/src/scout_rum_config.dart` — add `enablePerformanceMetrics` config flag

**Step 1: Add config flag**

In `lib/src/scout_rum_config.dart`, add to the class fields:

```dart
/// Whether to collect performance metrics (FPS, memory, CPU, frame times).
final bool enablePerformanceMetrics;
```

Add to constructor parameters:

```dart
this.enablePerformanceMetrics = true,
```

**Step 2: Enable metrics in FlutterOTel.initialize**

In `lib/src/scout_rum.dart`, change line 109:

```dart
enableMetrics: config.enablePerformanceMetrics,
```

---

### Task 2: View Session Tracking (time spent per screen)

**Files:**
- Modify: `lib/src/auto_name_navigator_observer.dart` — add `onScreenEnter` and `onScreenExit` callbacks
- Modify: `lib/src/scout_rum.dart` — create view_session spans
- Create: `test/view_session_test.dart`

**Step 1: Add callbacks to AutoNameNavigatorObserver**

Add new callback types to the constructor:

```dart
final void Function(String screenName)? onScreenEnter;
final void Function(String screenName, Duration timeSpent)? onScreenExit;
```

Add tracking state:

```dart
Stopwatch? _viewStopwatch;
String? _activeViewName;
```

In `_handlePush`, after setting `currentScreenName`:

```dart
// End previous view session
if (_activeViewName != null && _viewStopwatch != null) {
  onScreenExit?.call(_activeViewName!, _viewStopwatch!.elapsed);
}
// Start new view session
_activeViewName = resolvedName; // or name, depending on path
_viewStopwatch = Stopwatch()..start();
onScreenEnter?.call(_activeViewName!);
```

In `_handlePop`, when going back:

```dart
// End current view session
if (_activeViewName != null && _viewStopwatch != null) {
  onScreenExit?.call(_activeViewName!, _viewStopwatch!.elapsed);
}
// Restart timer for previous view
_activeViewName = name;
_viewStopwatch = Stopwatch()..start();
onScreenEnter?.call(name);
```

**Step 2: Wire up in scout_rum.dart**

In the `navigatorObserver` getter, add the new callbacks:

```dart
onScreenEnter: (screenName) {
  if (!isInitialized) return;
  addBreadcrumb('view_session', 'entered: $screenName');
},
onScreenExit: (screenName, timeSpent) {
  if (!isInitialized) return;
  final span = FlutterOTel.tracer.startSpan(
    'view_session',
    attributes: <String, Object>{
      'screen.name': screenName,
      'view.time_spent': timeSpent.inMilliseconds / 1000.0,
      if (_userId != null) 'enduser.id': _userId!,
      if (_userEmail != null) 'enduser.email': _userEmail!,
    }.toAttributes(),
  );
  addBreadcrumb('view_session', 'exited: $screenName (${timeSpent.inMilliseconds}ms)');
  span.end();
},
```

**Step 3: Write tests**

In `test/view_session_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/auto_name_navigator_observer.dart';

void main() {
  group('View session tracking', () {
    test('onScreenEnter fires on push', () {
      String? entered;
      final observer = AutoNameNavigatorObserver(
        onScreenEnter: (name) => entered = name,
      );

      final route = MaterialPageRoute(
        settings: const RouteSettings(name: '/home'),
        builder: (_) => const SizedBox(),
      );

      observer.didPush(route, null);
      expect(entered, '/home');
    });

    test('onScreenExit fires with time spent on second push', () async {
      String? exitedName;
      Duration? exitedDuration;

      final observer = AutoNameNavigatorObserver(
        onScreenEnter: (_) {},
        onScreenExit: (name, duration) {
          exitedName = name;
          exitedDuration = duration;
        },
      );

      final route1 = MaterialPageRoute(
        settings: const RouteSettings(name: '/home'),
        builder: (_) => const SizedBox(),
      );
      final route2 = MaterialPageRoute(
        settings: const RouteSettings(name: '/detail'),
        builder: (_) => const SizedBox(),
      );

      observer.didPush(route1, null);
      await Future.delayed(const Duration(milliseconds: 50));
      observer.didPush(route2, route1);

      expect(exitedName, '/home');
      expect(exitedDuration, isNotNull);
      expect(exitedDuration!.inMilliseconds, greaterThanOrEqualTo(40));
    });
  });
}
```

**Step 4: Run tests**

```bash
cd /Users/nimishgj/github/scout_flutter && flutter test test/view_session_test.dart -v
```

---

### Task 3: App Startup Time (cold + warm)

**Files:**
- Modify: `lib/src/scout_rum.dart` — measure cold start in `initialize()`, warm start on resume
- Modify: `lib/src/scout_rum_config.dart` — add `enableStartupTracking` flag

**Step 1: Add config flag**

In `lib/src/scout_rum_config.dart`:

```dart
/// Whether to track app startup time (cold and warm start).
final bool enableStartupTracking;
```

Constructor: `this.enableStartupTracking = true,`

**Step 2: Implement cold start**

In `lib/src/scout_rum.dart`, add static fields:

```dart
static Stopwatch? _coldStartStopwatch;
static bool _coldStartRecorded = false;
```

At the very top of `initialize()`, before `WidgetsFlutterBinding.ensureInitialized()`:

```dart
_coldStartStopwatch ??= Stopwatch()..start();
```

After all setup is done (end of `initialize`), add:

```dart
if (config.enableStartupTracking) {
  _measureColdStart();
}
```

New method:

```dart
static void _measureColdStart() {
  if (_coldStartRecorded || _coldStartStopwatch == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_coldStartRecorded) return;
    _coldStartRecorded = true;
    final duration = _coldStartStopwatch!.elapsed;
    _coldStartStopwatch!.stop();
    final span = FlutterOTel.tracer.startSpan(
      'app_startup',
      attributes: <String, Object>{
        'app_startup.type': 'cold',
        'app_startup.duration': duration.inMilliseconds / 1000.0,
        if (_userId != null) 'enduser.id': _userId!,
        if (_userEmail != null) 'enduser.email': _userEmail!,
      }.toAttributes(),
    );
    addBreadcrumb('startup', 'cold_start: ${duration.inMilliseconds}ms');
    span.end();
  });
}
```

**Step 3: Implement warm start**

Modify `_setupLifecycleTracking()` to track warm start:

```dart
static Stopwatch? _warmStartStopwatch;

static void _setupLifecycleTracking() {
  _lifecycleListener = AppLifecycleListener(
    onPause: () {
      addBreadcrumb('lifecycle', 'app_paused');
    },
    onResume: () {
      addBreadcrumb('lifecycle', 'app_resumed');
      if (_config?.enableStartupTracking == true) {
        _measureWarmStart();
      }
    },
    onInactive: () {
      // Start warm start timer when app goes inactive
      _warmStartStopwatch = Stopwatch()..start();
    },
    onExitRequested: () async {
      addBreadcrumb('lifecycle', 'app_exit_requested');
      return AppExitResponse.exit;
    },
  );
}

static void _measureWarmStart() {
  if (_warmStartStopwatch == null) return;
  final stopwatch = _warmStartStopwatch!;
  _warmStartStopwatch = null;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final duration = stopwatch.elapsed;
    stopwatch.stop();
    final span = FlutterOTel.tracer.startSpan(
      'app_startup',
      attributes: <String, Object>{
        'app_startup.type': 'warm',
        'app_startup.duration': duration.inMilliseconds / 1000.0,
        if (_userId != null) 'enduser.id': _userId!,
        if (_userEmail != null) 'enduser.email': _userEmail!,
      }.toAttributes(),
    );
    addBreadcrumb('startup', 'warm_start: ${duration.inMilliseconds}ms');
    span.end();
  });
}
```

---

### Task 4: Frame Timing Metrics (FPS, build time, raster time, frozen frames)

**Files:**
- Create: `lib/src/frame_metrics_collector.dart` — subscribes to SchedulerBinding frame timings
- Modify: `lib/src/scout_rum.dart` — wire up frame metrics collection
- Create: `test/frame_metrics_collector_test.dart`

**Step 1: Create FrameMetricsCollector**

Create `lib/src/frame_metrics_collector.dart`:

```dart
import 'dart:ui';

import 'package:flutter/scheduler.dart';

/// Collects frame timing metrics from Flutter's rendering pipeline.
///
/// Subscribes to [SchedulerBinding.addTimingsCallback] to receive
/// [FrameTiming] data for every rendered frame. Reports:
/// - Build duration (widget tree construction)
/// - Raster duration (GPU rasterization)
/// - Frozen frames (total frame time > 700ms)
class FrameMetricsCollector {
  final void Function(Duration buildTime, Duration rasterTime) onFrameTiming;
  final void Function(Duration totalDuration)? onFrozenFrame;
  final Duration frozenFrameThreshold;

  bool _collecting = false;

  FrameMetricsCollector({
    required this.onFrameTiming,
    this.onFrozenFrame,
    this.frozenFrameThreshold = const Duration(milliseconds: 700),
  });

  bool get isCollecting => _collecting;

  void start() {
    if (_collecting) return;
    _collecting = true;
    SchedulerBinding.instance.addTimingsCallback(_handleTimings);
  }

  void stop() {
    if (!_collecting) return;
    _collecting = false;
    SchedulerBinding.instance.removeTimingsCallback(_handleTimings);
  }

  void _handleTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildDuration = timing.buildDuration;
      final rasterDuration = timing.rasterDuration;
      final totalDuration = timing.totalSpan;

      onFrameTiming(buildDuration, rasterDuration);

      if (onFrozenFrame != null && totalDuration >= frozenFrameThreshold) {
        onFrozenFrame!(totalDuration);
      }
    }
  }
}
```

**Step 2: Wire up in scout_rum.dart**

Add import and static field:

```dart
import 'frame_metrics_collector.dart';

static FrameMetricsCollector? _frameMetricsCollector;
```

Add to `initialize()` after other setup:

```dart
if (config.enablePerformanceMetrics) {
  _setupFrameMetrics();
}
```

New method:

```dart
static void _setupFrameMetrics() {
  final meter = FlutterOTel.meter(name: 'scout.performance');

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
      final screenAttr = <String, Object>{
        if (_navObserver?.currentScreenName != null)
          'screen.name': _navObserver!.currentScreenName!,
      }.toAttributes();

      buildHistogram.record(
        buildTime.inMicroseconds / 1000000.0,
        screenAttr,
      );
      rasterHistogram.record(
        rasterTime.inMicroseconds / 1000000.0,
        screenAttr,
      );
    },
    onFrozenFrame: (duration) {
      if (!isInitialized) return;
      String? currentScreen;
      if (_navObserver != null) {
        currentScreen = _navObserver!.currentScreenName;
      }
      final span = FlutterOTel.tracer.startSpan(
        'frozen_frame',
        attributes: <String, Object>{
          'frozen_frame.duration': duration.inMilliseconds / 1000.0,
          if (currentScreen != null) 'screen.name': currentScreen,
          if (_userId != null) 'enduser.id': _userId!,
          if (_userEmail != null) 'enduser.email': _userEmail!,
        }.toAttributes(),
      );
      addBreadcrumb('frozen_frame', 'Frozen frame: ${duration.inMilliseconds}ms');
      span.end();
    },
  );
  _frameMetricsCollector!.start();
}
```

Add to `resetForTesting()`:

```dart
_frameMetricsCollector?.stop();
_frameMetricsCollector = null;
_coldStartStopwatch = null;
_coldStartRecorded = false;
_warmStartStopwatch = null;
```

---

### Task 5: Native Memory and CPU Metrics

**Files:**
- Modify: `android/src/main/kotlin/com/base14/scout_flutter/ScoutFlutterPlugin.kt` — add getMemoryUsage and getCpuUsage methods
- Modify: `ios/Classes/ScoutFlutterPlugin.swift` — add getMemoryUsage and getCpuUsage methods
- Modify: `lib/src/scout_platform_channel.dart` — add Dart-side methods
- Create: `lib/src/native_vitals_collector.dart` — periodic polling + OTel gauge recording
- Modify: `lib/src/scout_rum.dart` — wire up native vitals

**Step 1: Android native — memory and CPU**

Add to `ScoutFlutterPlugin.kt` in the `when` block:

```kotlin
"getMemoryUsage" -> {
    val runtime = Runtime.getRuntime()
    val usedMemory = runtime.totalMemory() - runtime.freeMemory()
    val maxMemory = runtime.maxMemory()
    result.success(mapOf(
        "used" to usedMemory,
        "max" to maxMemory
    ))
}
"getCpuUsage" -> {
    // Read from /proc/stat for overall CPU usage
    try {
        val pid = android.os.Process.myPid()
        val procFile = java.io.File("/proc/$pid/stat")
        val statLine = procFile.readText().trim().split(" ")
        // Fields 13 (utime) and 14 (stime) are user and system CPU time in clock ticks
        val utime = statLine[13].toLong()
        val stime = statLine[14].toLong()
        val totalTicks = utime + stime
        result.success(mapOf(
            "ticks" to totalTicks
        ))
    } catch (e: Exception) {
        result.success(mapOf("ticks" to -1L))
    }
}
```

**Step 2: iOS native — memory and CPU**

Add to `ScoutFlutterPlugin.swift` in the `switch`:

```swift
case "getMemoryUsage":
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result_code = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if result_code == KERN_SUCCESS {
        result(["used": info.resident_size, "max": ProcessInfo.processInfo.physicalMemory])
    } else {
        result(["used": -1, "max": -1])
    }

case "getCpuUsage":
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    let threadResult = task_threads(mach_task_self_, &threadList, &threadCount)
    var totalCpu = 0.0
    if threadResult == KERN_SUCCESS, let threads = threadList {
        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_BASIC_INFO_COUNT)
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            if infoResult == KERN_SUCCESS {
                let usage = Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                totalCpu += usage
            }
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
    }
    result(["cpu_percent": totalCpu])
```

**Step 3: Dart platform channel methods**

Add to `lib/src/scout_platform_channel.dart`:

```dart
static Future<Map<String, dynamic>> getMemoryUsage() async {
  final result = await _channel.invokeMapMethod<String, dynamic>('getMemoryUsage');
  return result ?? {};
}

static Future<Map<String, dynamic>> getCpuUsage() async {
  final result = await _channel.invokeMapMethod<String, dynamic>('getCpuUsage');
  return result ?? {};
}
```

**Step 4: Create NativeVitalsCollector**

Create `lib/src/native_vitals_collector.dart`:

```dart
import 'dart:async';

import 'scout_platform_channel.dart';

/// Periodically polls native platform for memory and CPU metrics.
class NativeVitalsCollector {
  final Duration interval;
  final void Function(int usedBytes, int maxBytes) onMemory;
  final void Function(double cpuPercent) onCpu;

  Timer? _timer;
  int? _lastCpuTicks;
  DateTime? _lastCpuTime;

  NativeVitalsCollector({
    this.interval = const Duration(milliseconds: 500),
    required this.onMemory,
    required this.onCpu,
  });

  bool get isCollecting => _timer != null;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _collect());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastCpuTicks = null;
    _lastCpuTime = null;
  }

  Future<void> _collect() async {
    try {
      final memory = await ScoutPlatformChannel.getMemoryUsage();
      final used = memory['used'] as int? ?? -1;
      final max = memory['max'] as int? ?? -1;
      if (used > 0) {
        onMemory(used, max);
      }
    } catch (_) {}

    try {
      final cpu = await ScoutPlatformChannel.getCpuUsage();
      // iOS returns cpu_percent directly
      if (cpu.containsKey('cpu_percent')) {
        final percent = (cpu['cpu_percent'] as num).toDouble();
        onCpu(percent);
      }
      // Android returns ticks — compute delta
      else if (cpu.containsKey('ticks')) {
        final ticks = cpu['ticks'] as int;
        if (ticks >= 0 && _lastCpuTicks != null && _lastCpuTime != null) {
          final elapsed = DateTime.now().difference(_lastCpuTime!).inMilliseconds;
          if (elapsed > 0) {
            final tickDelta = ticks - _lastCpuTicks!;
            // clock ticks are usually 100/sec (10ms each)
            final cpuMs = tickDelta * 10;
            final percent = (cpuMs / elapsed) * 100.0;
            onCpu(percent.clamp(0, 100));
          }
        }
        _lastCpuTicks = ticks;
        _lastCpuTime = DateTime.now();
      }
    } catch (_) {}
  }
}
```

**Step 5: Wire up in scout_rum.dart**

Add import and field:

```dart
import 'native_vitals_collector.dart';

static NativeVitalsCollector? _nativeVitalsCollector;
```

Add to `initialize()`:

```dart
if (config.enablePerformanceMetrics) {
  _setupNativeVitals();
}
```

New method:

```dart
static void _setupNativeVitals() {
  final meter = FlutterOTel.meter(name: 'scout.performance');

  final memoryGauge = meter.createGauge<double>(
    name: 'flutter.memory.usage',
    description: 'App memory usage',
    unit: 'By',
  );

  final cpuGauge = meter.createGauge<double>(
    name: 'flutter.cpu.usage',
    description: 'App CPU usage percentage',
    unit: '%',
  );

  _nativeVitalsCollector = NativeVitalsCollector(
    onMemory: (usedBytes, maxBytes) {
      final attrs = <String, Object>{
        if (_navObserver?.currentScreenName != null)
          'screen.name': _navObserver!.currentScreenName!,
      }.toAttributes();
      memoryGauge.record(usedBytes.toDouble(), attrs);
    },
    onCpu: (cpuPercent) {
      final attrs = <String, Object>{
        if (_navObserver?.currentScreenName != null)
          'screen.name': _navObserver!.currentScreenName!,
      }.toAttributes();
      cpuGauge.record(cpuPercent, attrs);
    },
  );
  _nativeVitalsCollector!.start();
}
```

Add to `resetForTesting()`:

```dart
_nativeVitalsCollector?.stop();
_nativeVitalsCollector = null;
```

---

### Task 6: Network Connectivity Type

**Files:**
- Modify: `pubspec.yaml` — add `connectivity_plus` dependency
- Modify: `lib/src/scout_rum.dart` — collect connectivity and add as resource attribute
- Modify: `lib/src/scout_rum_config.dart` — add `enableConnectivityTracking` flag

**Step 1: Add dependency**

In `pubspec.yaml` under dependencies:

```yaml
connectivity_plus: ^6.0.0
```

**Step 2: Add config flag**

In `lib/src/scout_rum_config.dart`:

```dart
/// Whether to track network connectivity type as a resource attribute.
final bool enableConnectivityTracking;
```

Constructor: `this.enableConnectivityTracking = true,`

**Step 3: Collect connectivity in initialize**

In `lib/src/scout_rum.dart`, add import:

```dart
import 'package:connectivity_plus/connectivity_plus.dart';
```

Add static field:

```dart
static String _connectivityType = 'unknown';
```

In `_collectDeviceAttributes()`, add after device info:

```dart
try {
  final connectivity = await Connectivity().checkConnectivity();
  if (connectivity.isNotEmpty) {
    _connectivityType = connectivity.first.name;
    attrs['network.connection.type'] = _connectivityType;
  }
} catch (_) {}
```

Also listen for changes — add to `initialize()`:

```dart
if (config.enableConnectivityTracking) {
  Connectivity().onConnectivityChanged.listen((result) {
    if (result.isNotEmpty) {
      _connectivityType = result.first.name;
    }
  });
}
```

Add `network.connection.type` to all span-creating methods by creating a helper:

```dart
static Map<String, Object> _commonAttributes() {
  return {
    if (_userId != null) 'enduser.id': _userId!,
    if (_userEmail != null) 'enduser.email': _userEmail!,
    if (_connectivityType != 'unknown')
      'network.connection.type': _connectivityType,
  };
}
```

Then use `..._commonAttributes()` in all span attribute maps instead of repeating the userId/userEmail checks.

---

### Task 7: Export barrel and cleanup

**Files:**
- Modify: `lib/scout_flutter.dart` — export new public types if needed
- Verify all new fields are in `resetForTesting()`

**Step 1: Verify exports**

The new files (`frame_metrics_collector.dart`, `native_vitals_collector.dart`) are internal — no new exports needed in `lib/scout_flutter.dart`.

**Step 2: Verify resetForTesting**

Ensure `resetForTesting()` in `scout_rum.dart` includes:

```dart
_frameMetricsCollector?.stop();
_frameMetricsCollector = null;
_nativeVitalsCollector?.stop();
_nativeVitalsCollector = null;
_coldStartStopwatch = null;
_coldStartRecorded = false;
_warmStartStopwatch = null;
```

---

### Task 8: Integration test with platform_design app

**Manual verification steps:**

1. Run `flutter run` in platform_design
2. Set up `adb reverse tcp:4318 tcp:4328`
3. Navigate between tabs — verify `view_session` spans with `view.time_spent`
4. Background and resume app — verify `app_startup` span with `type: warm`
5. Check collector for `frozen_frame` spans (may need to trigger heavy UI)
6. Verify OTel metrics in collector: `flutter.frame.build_time`, `flutter.frame.raster_time`, `flutter.memory.usage`, `flutter.cpu.usage`
7. Verify `network.connection.type` attribute on spans
8. Check cold start: kill app, relaunch — verify `app_startup` span with `type: cold`
