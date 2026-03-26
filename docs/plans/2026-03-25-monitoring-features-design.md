# Monitoring Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add jank/long-task detection, native ANR detection, and screen load time tracking to scout_flutter.

**Architecture:** Three independent features. Jank detection is pure Dart using `Future.delayed` polling (Datadog's approach). ANR detection requires converting scout_flutter from a pure Dart package to a Flutter plugin with native Kotlin/Swift watchdog threads communicating via MethodChannel. Screen load time extends the existing `AutoNameNavigatorObserver` with `addPostFrameCallback` timing.

**Tech Stack:** Dart, Kotlin (Android), Swift (iOS), MethodChannel, OpenTelemetry spans via `flutterrific_opentelemetry`

**Reference:** Datadog Flutter SDK at `/tmp/dd-sdk-flutter` — specifically `rum_long_task_observer.dart`, `DatadogRumPlugin.kt`, `DatadogRumPlugin.swift`, `navigation_observer.dart`

---

## Task 1: Add config fields for new features

**Files:**
- Modify: `lib/src/scout_rum_config.dart`
- Modify: `test/scout_rum_config_test.dart`

**Step 1: Write failing tests**

Add tests for new config fields in `test/scout_rum_config_test.dart`:

```dart
test('default config has long task detection enabled', () {
  final config = ScoutFlutterConfig(
    serviceName: 'test',
    endpoint: 'http://localhost:4318',
  );
  expect(config.enableLongTaskDetection, true);
  expect(config.longTaskThresholdMs, 100);
});

test('default config has ANR detection enabled', () {
  final config = ScoutFlutterConfig(
    serviceName: 'test',
    endpoint: 'http://localhost:4318',
  );
  expect(config.enableAnrDetection, true);
  expect(config.anrThresholdMs, 5000);
});

test('longTaskThresholdMs enforces minimum of 20', () {
  final config = ScoutFlutterConfig(
    serviceName: 'test',
    endpoint: 'http://localhost:4318',
    longTaskThresholdMs: 5,
  );
  expect(config.longTaskThresholdMs, 20);
});

test('config accepts custom thresholds', () {
  final config = ScoutFlutterConfig(
    serviceName: 'test',
    endpoint: 'http://localhost:4318',
    longTaskThresholdMs: 200,
    anrThresholdMs: 3000,
  );
  expect(config.longTaskThresholdMs, 200);
  expect(config.anrThresholdMs, 3000);
});
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/nimishgj/github/scout_flutter && flutter test test/scout_rum_config_test.dart`
Expected: FAIL — fields don't exist

**Step 3: Add fields to ScoutFlutterConfig**

In `lib/src/scout_rum_config.dart`, add to the constructor and class body:

```dart
this.enableLongTaskDetection = true,
this.longTaskThresholdMs = 100,
this.enableAnrDetection = true,
this.anrThresholdMs = 5000,
```

Fields:
```dart
final bool enableLongTaskDetection;
final int longTaskThresholdMs;
final bool enableAnrDetection;
final int anrThresholdMs;
```

Enforce minimum threshold in constructor body or use a late final:
```dart
// In constructor, clamp longTaskThresholdMs
longTaskThresholdMs = longTaskThresholdMs < 20 ? 20 : longTaskThresholdMs;
```

Since the class is `@immutable`, use an initializer list or a factory. The simplest approach: use a private constructor with a public factory or just store `max(20, longTaskThresholdMs)` via an initializer.

**Step 4: Run tests to verify they pass**

Run: `cd /Users/nimishgj/github/scout_flutter && flutter test test/scout_rum_config_test.dart`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/src/scout_rum_config.dart test/scout_rum_config_test.dart
git commit -m "feat: add config fields for long task, ANR detection"
```

---

## Task 2: Implement long task / jank detector

**Files:**
- Create: `lib/src/long_task_detector.dart`
- Create: `test/long_task_detector_test.dart`

**Design (modeled after Datadog's `RumLongTaskObserver`):**

A class that:
1. Runs a `Future.delayed(13ms)` polling loop on the Dart event loop
2. Measures actual elapsed time between iterations
3. If elapsed > `longTaskThresholdMs`, reports a long task span
4. Implements `WidgetsBindingObserver` to pause when app is backgrounded
5. Has `start()` and `stop()` methods

```dart
import 'package:flutter/widgets.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';

class LongTaskDetector with WidgetsBindingObserver {
  LongTaskDetector({
    required this.thresholdMs,
    this.onLongTask,
  });

  final int thresholdMs;
  final void Function(int durationMs)? onLongTask;
  bool _detecting = false;

  void start() {
    _detecting = true;
    WidgetsBinding.instance.addObserver(this);
    _pollLoop();
  }

  void stop() {
    _detecting = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  Future<void> _pollLoop() async {
    var lastCheck = DateTime.now().millisecondsSinceEpoch;
    while (_detecting) {
      await Future<void>.delayed(const Duration(milliseconds: 13));
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - lastCheck;
      if (_detecting && elapsed > thresholdMs) {
        _reportLongTask(elapsed);
      }
      lastCheck = now;
    }
  }

  void _reportLongTask(int durationMs) {
    final span = FlutterOTel.tracer.startSpan(
      'long_task',
      attributes: <String, Object>{
        'long_task.duration_ms': durationMs,
      }.toAttributes(),
    );
    span.end();
    onLongTask?.call(durationMs);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _detecting = false;
    } else if (state == AppLifecycleState.resumed) {
      _detecting = true;
      _pollLoop();
    }
  }
}
```

**Step 1: Write failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/long_task_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LongTaskDetector can be instantiated with threshold', () {
    final detector = LongTaskDetector(thresholdMs: 100);
    expect(detector.thresholdMs, 100);
  });

  test('LongTaskDetector detects long task when event loop is blocked', () async {
    int? reportedDuration;
    final detector = LongTaskDetector(
      thresholdMs: 50,
      onLongTask: (duration) => reportedDuration = duration,
    );
    detector.start();

    // Simulate blocking the event loop for ~100ms
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsedMilliseconds < 100) {
      // busy wait to block event loop
    }

    // Give the poll loop a chance to detect it
    await Future<void>.delayed(const Duration(milliseconds: 50));

    detector.stop();
    expect(reportedDuration, isNotNull);
    expect(reportedDuration!, greaterThanOrEqualTo(50));
  });

  test('LongTaskDetector does not report below threshold', () async {
    int? reportedDuration;
    final detector = LongTaskDetector(
      thresholdMs: 500,
      onLongTask: (duration) => reportedDuration = duration,
    );
    detector.start();

    // No blocking — normal event loop
    await Future<void>.delayed(const Duration(milliseconds: 100));

    detector.stop();
    expect(reportedDuration, isNull);
  });
}
```

Note: The OTel span creation will need to be abstracted or conditionally called in tests. Consider accepting a callback (`onLongTask`) for testability and having `ScoutFlutter` wire the span creation.

**Step 2: Run tests to verify they fail**

Run: `cd /Users/nimishgj/github/scout_flutter && flutter test test/long_task_detector_test.dart`
Expected: FAIL — file doesn't exist

**Step 3: Implement `LongTaskDetector`**

Create `lib/src/long_task_detector.dart` as shown above. For testability, the span creation should be done via the `onLongTask` callback, and `ScoutFlutter` wires the OTel reporting.

**Step 4: Run tests to verify they pass**

Run: `cd /Users/nimishgj/github/scout_flutter && flutter test test/long_task_detector_test.dart`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/src/long_task_detector.dart test/long_task_detector_test.dart
git commit -m "feat: add long task / jank detector"
```

---

## Task 3: Scaffold native plugin infrastructure

**Files:**
- Modify: `pubspec.yaml` (add plugin platform declaration)
- Create: `lib/src/scout_platform_channel.dart` (MethodChannel Dart side)
- Create: `android/src/main/kotlin/com/base14/scout_flutter/ScoutFlutterPlugin.kt`
- Create: `android/src/main/AndroidManifest.xml`
- Create: `android/build.gradle`
- Create: `ios/Classes/ScoutFlutterPlugin.swift`
- Create: `ios/scout_flutter.podspec`

**Step 1: Update pubspec.yaml with plugin declaration**

Add to `pubspec.yaml`:

```yaml
flutter:
  plugin:
    platforms:
      android:
        package: com.base14.scout_flutter
        pluginClass: ScoutFlutterPlugin
      ios:
        pluginClass: ScoutFlutterPlugin
```

**Step 2: Create Dart platform channel**

`lib/src/scout_platform_channel.dart`:

```dart
import 'package:flutter/services.dart';

class ScoutPlatformChannel {
  static const _channel = MethodChannel('com.base14.scout_flutter');

  static Future<void> startAnrDetection({required int thresholdMs}) async {
    await _channel.invokeMethod('startAnrDetection', {
      'thresholdMs': thresholdMs,
    });
  }

  static Future<void> stopAnrDetection() async {
    await _channel.invokeMethod('stopAnrDetection');
  }

  /// Set up handler for ANR events from native side
  static void setAnrHandler(void Function(int durationMs) onAnr) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAnrDetected') {
        final durationMs = call.arguments as int;
        onAnr(durationMs);
      }
    });
  }
}
```

**Step 3: Create Android plugin**

`android/build.gradle`:
```groovy
group 'com.base14.scout_flutter'
version '1.0'

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.1.0'
        classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.0'
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace 'com.base14.scout_flutter'
    compileSdk 35

    defaultConfig {
        minSdk 21
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = '1.8'
    }
}
```

`android/src/main/AndroidManifest.xml`:
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.base14.scout_flutter">
</manifest>
```

`android/src/main/kotlin/com/base14/scout_flutter/ScoutFlutterPlugin.kt`:
```kotlin
package com.base14.scout_flutter

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class ScoutFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var anrWatchdog: AnrWatchdog? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.base14.scout_flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        anrWatchdog?.stop()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startAnrDetection" -> {
                val thresholdMs = call.argument<Int>("thresholdMs") ?: 5000
                anrWatchdog?.stop()
                anrWatchdog = AnrWatchdog(thresholdMs.toLong()) { durationMs ->
                    Handler(Looper.getMainLooper()).post {
                        channel.invokeMethod("onAnrDetected", durationMs)
                    }
                }
                anrWatchdog?.start()
                result.success(null)
            }
            "stopAnrDetection" -> {
                anrWatchdog?.stop()
                anrWatchdog = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
```

**Step 4: Create Android ANR watchdog**

`android/src/main/kotlin/com/base14/scout_flutter/AnrWatchdog.kt`:
```kotlin
package com.base14.scout_flutter

import android.os.Handler
import android.os.Looper

class AnrWatchdog(
    private val thresholdMs: Long,
    private val onAnrDetected: (Long) -> Unit
) {
    private var watchdogThread: Thread? = null
    @Volatile private var running = false
    @Volatile private var responded = true

    private val mainHandler = Handler(Looper.getMainLooper())

    fun start() {
        running = true
        responded = true
        watchdogThread = Thread({
            while (running) {
                responded = false
                mainHandler.post { responded = true }

                try {
                    Thread.sleep(thresholdMs)
                } catch (e: InterruptedException) {
                    break
                }

                if (!responded && running) {
                    onAnrDetected(thresholdMs)
                }
            }
        }, "scout-anr-watchdog")
        watchdogThread?.start()
    }

    fun stop() {
        running = false
        watchdogThread?.interrupt()
        watchdogThread = null
    }
}
```

**Step 5: Create iOS plugin**

`ios/scout_flutter.podspec`:
```ruby
Pod::Spec.new do |s|
  s.name             = 'scout_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Scout Flutter monitoring plugin'
  s.description      = 'Native ANR/app hang detection for Scout Flutter'
  s.homepage         = 'https://github.com/base-14/scout_flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'base-14' => 'info@base14.dev' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'
end
```

`ios/Classes/ScoutFlutterPlugin.swift`:
```swift
import Flutter

public class ScoutFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var hangWatchdog: AppHangWatchdog?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.base14.scout_flutter",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScoutFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startAnrDetection":
            let args = call.arguments as? [String: Any]
            let thresholdMs = args?["thresholdMs"] as? Int ?? 5000
            hangWatchdog?.stop()
            hangWatchdog = AppHangWatchdog(thresholdMs: thresholdMs) { [weak self] durationMs in
                DispatchQueue.main.async {
                    self?.channel.invokeMethod("onAnrDetected", arguments: durationMs)
                }
            }
            hangWatchdog?.start()
            result(nil)
        case "stopAnrDetection":
            hangWatchdog?.stop()
            hangWatchdog = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
```

`ios/Classes/AppHangWatchdog.swift`:
```swift
import Foundation

class AppHangWatchdog {
    private let thresholdMs: Int
    private let onHangDetected: (Int) -> Void
    private var watchdogQueue: DispatchQueue?
    private var running = false

    init(thresholdMs: Int, onHangDetected: @escaping (Int) -> Void) {
        self.thresholdMs = thresholdMs
        self.onHangDetected = onHangDetected
    }

    func start() {
        running = true
        watchdogQueue = DispatchQueue(label: "com.base14.scout_flutter.anr_watchdog")
        watchdogQueue?.async { [weak self] in
            self?.watchdogLoop()
        }
    }

    func stop() {
        running = false
        watchdogQueue = nil
    }

    private func watchdogLoop() {
        while running {
            var responded = false

            DispatchQueue.main.async {
                responded = true
            }

            let deadline = DispatchTime.now() + .milliseconds(thresholdMs)
            Thread.sleep(forTimeInterval: Double(thresholdMs) / 1000.0)

            if !responded && running {
                onHangDetected(thresholdMs)
            }
        }
    }
}
```

**Step 6: Commit**

```bash
git add pubspec.yaml lib/src/scout_platform_channel.dart android/ ios/
git commit -m "feat: scaffold native plugin infrastructure for ANR detection"
```

---

## Task 4: Integrate ANR detection into ScoutFlutter

**Files:**
- Modify: `lib/src/scout_rum.dart`
- Modify: `lib/scout_flutter.dart` (export platform channel if needed)

**Step 1: Wire ANR detection in `ScoutFlutter.initialize()`**

In `scout_rum.dart`, add to `initialize()`:

```dart
// After existing setup...
if (config.enableAnrDetection) {
  ScoutPlatformChannel.setAnrHandler((durationMs) {
    final span = FlutterOTel.tracer.startSpan(
      'anr',
      attributes: <String, Object>{
        'anr.duration_ms': durationMs,
        if (_userId != null) 'enduser.id': _userId!,
        if (_userEmail != null) 'enduser.email': _userEmail!,
      }.toAttributes(),
    );
    span.end();
    _breadcrumbManager.record('anr', 'App not responding: ${durationMs}ms');
  });
  await ScoutPlatformChannel.startAnrDetection(
    thresholdMs: config.anrThresholdMs,
  );
}
```

In `shutdown()`:
```dart
if (_config?.enableAnrDetection == true) {
  await ScoutPlatformChannel.stopAnrDetection();
}
```

**Step 2: Wire long task detection in `ScoutFlutter.initialize()`**

```dart
if (config.enableLongTaskDetection) {
  _longTaskDetector = LongTaskDetector(
    thresholdMs: config.longTaskThresholdMs,
    onLongTask: (durationMs) {
      final span = FlutterOTel.tracer.startSpan(
        'long_task',
        attributes: <String, Object>{
          'long_task.duration_ms': durationMs,
          if (_userId != null) 'enduser.id': _userId!,
          if (_userEmail != null) 'enduser.email': _userEmail!,
        }.toAttributes(),
      );
      span.end();
      _breadcrumbManager.record('long_task', 'Long task: ${durationMs}ms');
    },
  );
  _longTaskDetector!.start();
}
```

**Step 3: Commit**

```bash
git add lib/src/scout_rum.dart
git commit -m "feat: integrate long task and ANR detection into ScoutFlutter"
```

---

## Task 5: Implement screen load time (FBC)

**Files:**
- Modify: `lib/src/auto_name_navigator_observer.dart`
- Modify: `test/auto_name_navigator_observer_test.dart`

**Design:** When `didPush` fires, record `DateTime.now()`. Register `WidgetsBinding.instance.addPostFrameCallback`. When callback fires, calculate duration and create `screen_load` span.

**Step 1: Write failing test**

```dart
test('reports screen load time on push', () async {
  // Push a route, verify a screen_load span is created
  // with screen.name and screen.load_time_ms attributes
});
```

**Step 2: Add FBC tracking to `AutoNameNavigatorObserver`**

In `didPush()`, after existing screen_view span logic:

```dart
final pushTime = DateTime.now();

WidgetsBinding.instance.addPostFrameCallback((_) {
  final loadTimeMs = DateTime.now().difference(pushTime).inMilliseconds;
  final screenName = _resolveScreenName(route);

  final span = FlutterOTel.tracer.startSpan(
    'screen_load',
    attributes: <String, Object>{
      'screen.name': screenName,
      'screen.load_time_ms': loadTimeMs,
    }.toAttributes(),
  );
  span.end();
});
```

**Step 3: Run tests**

Run: `cd /Users/nimishgj/github/scout_flutter && flutter test test/auto_name_navigator_observer_test.dart`

**Step 4: Commit**

```bash
git add lib/src/auto_name_navigator_observer.dart test/auto_name_navigator_observer_test.dart
git commit -m "feat: add screen load time (FBC) measurement"
```

---

## Task 6: Update barrel export and example app

**Files:**
- Modify: `lib/scout_flutter.dart`
- Modify: `example/lib/main.dart`

**Step 1: Update exports if needed**

Ensure `scout_flutter.dart` exports any new public types (config fields are already exported via `ScoutFlutterConfig`).

**Step 2: Update example app to demonstrate new features**

All three features are auto-enabled by default, so the example app just needs a comment or log noting that jank/ANR/screen-load are active.

**Step 3: Commit**

```bash
git add lib/scout_flutter.dart example/lib/main.dart
git commit -m "feat: update exports and example for new monitoring features"
```

---

## Task 7: Update platform_design test app to use local dependency

**Files:**
- Modify: `/Users/nimishgj/github/flutter/samples/platform_design/pubspec.yaml`

**Step 1: Switch from git to local path dependency**

```yaml
scout_flutter:
  path: /Users/nimishgj/github/scout_flutter
```

**Step 2: Run and verify traces appear in OTel collector**

```bash
cd /Users/nimishgj/github/flutter/samples/platform_design
flutter pub get
flutter run
```

Check collector logs for `long_task`, `anr`, and `screen_load` spans.

**Step 3: After verification, switch back to git dependency**

```yaml
scout_flutter:
  git:
    url: https://github.com/base-14/scout_flutter.git
```
