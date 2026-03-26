# Phase 3: Network, Sessions, Logging, Offline, Filtering — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add HTTP/network tracking, distributed tracing, session management, structured logging, offline queueing, event filtering, and Dio interceptor — all auto-activated via `initialize()`.

**Architecture:** HttpOverrides.global intercepts all dart:io HTTP traffic. A SessionManager handles UUID v4 session IDs with inactivity rotation and sampling. Exporter decorators (OfflineAware, BeforeSend, Sampled) wrap the base OTLP exporters for resilience and filtering. A new OTLP log exporter completes the observability triad. File-based offline queue in app temp directory persists failed exports.

**Tech Stack:** Dart/Flutter, dartastic_opentelemetry (protobuf for traces/metrics/logs), connectivity_plus, path_provider, dio.

**Constraints:**
- No forking upstream repos
- No Co-Authored-By in commit messages
- No docs/plans committed
- All existing 62 tests must keep passing

---

## Task 1: SessionManager

**Files:**
- Create: `lib/src/session_manager.dart`
- Test: `test/session_manager_test.dart`

**Context:** Every span, metric, and log needs a `session.id` attribute. Sessions rotate after inactivity timeout. Sampling is per-session.

**Step 1: Write the failing test**

```dart
// test/session_manager_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/session_manager.dart';

void main() {
  group('SessionManager', () {
    late SessionManager manager;

    setUp(() {
      manager = SessionManager(
        sampleRate: 100.0,
        timeoutMinutes: 30,
      );
    });

    test('generates a valid UUID v4 session ID', () {
      final id = manager.sessionId;
      expect(id, isNotEmpty);
      // UUID v4 format: 8-4-4-4-12 hex chars
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(id),
        isTrue,
      );
    });

    test('returns same session ID on repeated access', () {
      final id1 = manager.sessionId;
      final id2 = manager.sessionId;
      expect(id1, equals(id2));
    });

    test('isSampled is true when sampleRate is 100', () {
      final m = SessionManager(sampleRate: 100.0, timeoutMinutes: 30);
      expect(m.isSampled, isTrue);
    });

    test('isSampled is false when sampleRate is 0', () {
      final m = SessionManager(sampleRate: 0.0, timeoutMinutes: 30);
      expect(m.isSampled, isFalse);
    });

    test('onBackground + onForeground within timeout keeps same session', () {
      final id1 = manager.sessionId;
      manager.onBackground();
      // Simulate short background (no way to fast-forward real time in unit test,
      // but since timeout is 30 min, immediate foreground should keep session)
      manager.onForeground();
      expect(manager.sessionId, equals(id1));
    });

    test('rotateSession creates new session ID', () {
      final id1 = manager.sessionId;
      manager.rotateSession();
      final id2 = manager.sessionId;
      expect(id2, isNot(equals(id1)));
    });

    test('rotateSession re-rolls sampling decision', () {
      // With sampleRate 0, every rotation should be sampled out
      final m = SessionManager(sampleRate: 0.0, timeoutMinutes: 30);
      m.rotateSession();
      expect(m.isSampled, isFalse);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/session_manager_test.dart`
Expected: FAIL — `session_manager.dart` doesn't exist

**Step 3: Write minimal implementation**

```dart
// lib/src/session_manager.dart
import 'dart:math';

class SessionManager {
  final double _sampleRate;
  final int _timeoutMinutes;
  final Random _random = Random.secure();

  String _sessionId;
  bool _isSampled;
  DateTime? _backgroundedAt;

  SessionManager({
    required double sampleRate,
    required int timeoutMinutes,
  })  : _sampleRate = sampleRate.clamp(0.0, 100.0),
        _timeoutMinutes = timeoutMinutes,
        _sessionId = '',
        _isSampled = false {
    _sessionId = _generateUuidV4();
    _isSampled = _rollSampling();
  }

  String get sessionId => _sessionId;
  bool get isSampled => _isSampled;

  void onBackground() {
    _backgroundedAt = DateTime.now();
  }

  void onForeground() {
    if (_backgroundedAt != null) {
      final elapsed = DateTime.now().difference(_backgroundedAt!);
      if (elapsed.inMinutes >= _timeoutMinutes) {
        rotateSession();
      }
      _backgroundedAt = null;
    }
  }

  void rotateSession() {
    _sessionId = _generateUuidV4();
    _isSampled = _rollSampling();
  }

  bool _rollSampling() {
    if (_sampleRate >= 100.0) return true;
    if (_sampleRate <= 0.0) return false;
    return _random.nextDouble() * 100.0 < _sampleRate;
  }

  String _generateUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
```

**Step 4: Run test to verify it passes**

Run: `flutter test test/session_manager_test.dart`
Expected: All 7 tests PASS

**Step 5: Commit**

```bash
git add lib/src/session_manager.dart test/session_manager_test.dart
git commit -m "feat: add SessionManager with UUID v4, rotation, and sampling"
```

---

## Task 2: Add new config fields to ScoutFlutterConfig

**Files:**
- Modify: `lib/src/scout_rum_config.dart`
- Test: `test/scout_rum_config_test.dart`

**Context:** Add all Phase 3 config fields. The `beforeSend` callback type and `ignoreUrlPatterns` need type definitions.

**Step 1: Write the failing test**

```dart
// test/scout_rum_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_rum_config.dart';

void main() {
  group('ScoutFlutterConfig Phase 3 fields', () {
    test('defaults are correct', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost:4318',
      );

      expect(config.enableNetworkTracking, isTrue);
      expect(config.ignoreUrlPatterns, isNull);
      expect(config.firstPartyHosts, isNull);
      expect(config.sessionSampleRate, 100.0);
      expect(config.sessionTimeoutMinutes, 30);
      expect(config.enableLogging, isTrue);
      expect(config.capturePrintStatements, isFalse);
      expect(config.maxOfflineStorageMb, 5);
      expect(config.beforeSend, isNull);
    });

    test('custom values are accepted', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost:4318',
        enableNetworkTracking: false,
        ignoreUrlPatterns: [RegExp(r'healthcheck')],
        firstPartyHosts: ['api.example.com'],
        sessionSampleRate: 50.0,
        sessionTimeoutMinutes: 15,
        enableLogging: false,
        capturePrintStatements: true,
        maxOfflineStorageMb: 10,
        beforeSend: (event) => event,
      );

      expect(config.enableNetworkTracking, isFalse);
      expect(config.ignoreUrlPatterns, hasLength(1));
      expect(config.firstPartyHosts, ['api.example.com']);
      expect(config.sessionSampleRate, 50.0);
      expect(config.sessionTimeoutMinutes, 15);
      expect(config.enableLogging, isFalse);
      expect(config.capturePrintStatements, isTrue);
      expect(config.maxOfflineStorageMb, 10);
      expect(config.beforeSend, isNotNull);
    });

    test('sessionSampleRate is clamped to 0-100', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost:4318',
        sessionSampleRate: 150.0,
      );
      expect(config.sessionSampleRate, 100.0);

      final config2 = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost:4318',
        sessionSampleRate: -10.0,
      );
      expect(config2.sessionSampleRate, 0.0);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/scout_rum_config_test.dart`
Expected: FAIL — fields don't exist

**Step 3: Write minimal implementation**

Add to `lib/src/scout_rum_config.dart`:

```dart
/// Callback to filter/modify events before export.
/// Return the event map to send, or null to drop it.
/// The map includes a 'type' field: "span", "metric", or "log".
typedef BeforeSendCallback = Map<String, dynamic>? Function(
    Map<String, dynamic> event);
```

Add these fields to `ScoutFlutterConfig`:

```dart
  /// Whether to auto-track HTTP requests via HttpOverrides.
  final bool enableNetworkTracking;

  /// URL patterns to exclude from network tracking.
  final List<RegExp>? ignoreUrlPatterns;

  /// Hosts that receive W3C traceparent headers for distributed tracing.
  /// If null or empty, no trace headers are injected.
  final List<String>? firstPartyHosts;

  /// Percentage of sessions to sample (0.0-100.0). Default 100.0 (all).
  final double sessionSampleRate;

  /// Minutes of inactivity before rotating the session. Default 30.
  final int sessionTimeoutMinutes;

  /// Whether to enable structured log export via OTLP.
  final bool enableLogging;

  /// Whether to capture print()/debugPrint() as info-level logs.
  final bool capturePrintStatements;

  /// Max offline storage in MB for failed exports. Default 5.
  final int maxOfflineStorageMb;

  /// Callback to filter/modify events before export.
  final BeforeSendCallback? beforeSend;
```

Add to constructor parameters:

```dart
    this.enableNetworkTracking = true,
    this.ignoreUrlPatterns,
    this.firstPartyHosts,
    double sessionSampleRate = 100.0,
    this.sessionTimeoutMinutes = 30,
    this.enableLogging = true,
    this.capturePrintStatements = false,
    this.maxOfflineStorageMb = 5,
    this.beforeSend,
```

Add to initializer list:

```dart
       sessionSampleRate = sessionSampleRate.clamp(0.0, 100.0);
```

Note: `sessionSampleRate` must NOT use `this.` prefix since it's clamped. Same pattern as `longTaskThresholdMs`.

**Step 4: Run tests**

Run: `flutter test test/scout_rum_config_test.dart`
Expected: All 3 tests PASS

Run: `flutter test`
Expected: All existing tests PASS (no breaking changes — all new fields have defaults)

**Step 5: Commit**

```bash
git add lib/src/scout_rum_config.dart test/scout_rum_config_test.dart
git commit -m "feat: add Phase 3 config fields for network, sessions, logging, offline, filtering"
```

---

## Task 3: OfflineQueue — file-based persistence

**Files:**
- Create: `lib/src/offline_queue.dart`
- Test: `test/offline_queue_test.dart`
- Modify: `pubspec.yaml` — add `path_provider: ^2.1.0`

**Context:** When OTLP export fails, batches are written to disk as JSON-lines files. On connectivity restore or periodic flush, files are read and re-exported. Oldest files deleted when storage cap exceeded.

**Step 1: Add path_provider dependency**

Add to `pubspec.yaml` dependencies:
```yaml
  path_provider: ^2.1.0
```

Run: `flutter pub get`

**Step 2: Write the failing test**

```dart
// test/offline_queue_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/offline_queue.dart';

void main() {
  late Directory tempDir;
  late OfflineQueue queue;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scout_test_');
    queue = OfflineQueue(
      directory: tempDir,
      maxStorageMb: 1,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('OfflineQueue', () {
    test('enqueue writes a file', () async {
      final batch = [
        {'type': 'span', 'name': 'test_span'},
      ];
      await queue.enqueue('spans', batch);

      final files = tempDir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.first.path, contains('spans_'));
    });

    test('dequeueAll reads and deletes files', () async {
      await queue.enqueue('spans', [{'name': 'span1'}]);
      await queue.enqueue('metrics', [{'name': 'metric1'}]);

      final batches = await queue.dequeueAll();
      expect(batches, hasLength(2));

      // Files should be deleted after dequeue
      final files = tempDir.listSync().whereType<File>().toList();
      expect(files, isEmpty);
    });

    test('enforces storage cap by deleting oldest files', () async {
      // Write enough data to exceed 1MB cap
      final largeBatch = List.generate(
        5000,
        (i) => {'key': 'value_$i', 'data': 'x' * 200},
      );
      await queue.enqueue('spans', largeBatch);
      await queue.enqueue('spans', largeBatch);
      await queue.enqueue('spans', largeBatch);

      await queue.enforceStorageCap();

      final totalSize = tempDir
          .listSync()
          .whereType<File>()
          .fold<int>(0, (sum, f) => sum + f.lengthSync());
      expect(totalSize, lessThanOrEqualTo(1 * 1024 * 1024));
    });

    test('dequeueAll returns empty list when no files', () async {
      final batches = await queue.dequeueAll();
      expect(batches, isEmpty);
    });

    test('batch roundtrip preserves data', () async {
      final original = [
        {'type': 'span', 'name': 'test', 'value': 42},
      ];
      await queue.enqueue('spans', original);

      final batches = await queue.dequeueAll();
      expect(batches.first.signal, 'spans');
      expect(batches.first.events, equals(original));
    });
  });
}
```

**Step 3: Run test to verify it fails**

Run: `flutter test test/offline_queue_test.dart`
Expected: FAIL — `offline_queue.dart` doesn't exist

**Step 4: Write minimal implementation**

```dart
// lib/src/offline_queue.dart
import 'dart:convert';
import 'dart:io';

class OfflineBatch {
  final String signal;
  final List<Map<String, dynamic>> events;

  OfflineBatch({required this.signal, required this.events});
}

class OfflineQueue {
  final Directory directory;
  final int maxStorageMb;

  OfflineQueue({
    required this.directory,
    required this.maxStorageMb,
  });

  Future<void> enqueue(
      String signal, List<Map<String, dynamic>> events) async {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${directory.path}/${signal}_$timestamp.jsonl');
    final lines = events.map((e) => jsonEncode(e)).join('\n');
    await file.writeAsString(lines);
    await enforceStorageCap();
  }

  Future<List<OfflineBatch>> dequeueAll() async {
    if (!directory.existsSync()) return [];

    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path)); // oldest first

    final batches = <OfflineBatch>[];
    for (final file in files) {
      try {
        final content = await file.readAsString();
        final lines = content.split('\n').where((l) => l.isNotEmpty);
        final events = lines
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .toList();
        // Extract signal type from filename: "spans_123456.jsonl" → "spans"
        final fileName = file.uri.pathSegments.last;
        final signal = fileName.split('_').first;
        batches.add(OfflineBatch(signal: signal, events: events));
        await file.delete();
      } catch (_) {
        // Corrupted file — delete and skip
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    return batches;
  }

  Future<void> enforceStorageCap() async {
    if (!directory.existsSync()) return;
    final maxBytes = maxStorageMb * 1024 * 1024;

    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path)); // oldest first

    var totalSize = files.fold<int>(0, (sum, f) => sum + f.lengthSync());

    var i = 0;
    while (totalSize > maxBytes && i < files.length) {
      totalSize -= files[i].lengthSync();
      files[i].deleteSync();
      i++;
    }
  }
}
```

**Step 5: Run tests**

Run: `flutter test test/offline_queue_test.dart`
Expected: All 5 tests PASS

**Step 6: Commit**

```bash
git add pubspec.yaml lib/src/offline_queue.dart test/offline_queue_test.dart
git commit -m "feat: add file-based offline queue for failed exports"
```

---

## Task 4: FixedHttpLogExporter — OTLP /v1/logs export

**Files:**
- Create: `lib/src/fixed_http_log_exporter.dart`
- Test: `test/fixed_http_log_exporter_test.dart`

**Context:** dartastic_opentelemetry has log protobuf definitions at:
- `proto/collector/logs/v1/logs_service.pb.dart` → `ExportLogsServiceRequest`
- `proto/logs/v1/logs.pb.dart` → `LogRecord`, `ResourceLogs`, `ScopeLogs`
- `proto/logs/v1/logs.pbenum.dart` → `SeverityNumber`
- `proto/common/v1/common.pb.dart` → `AnyValue`, `KeyValue`, `InstrumentationScope`

Follow the same pattern as `FixedHttpMetricExporter` — create protobuf messages manually to avoid the frozen default bug.

**Step 1: Write the failing test**

```dart
// test/fixed_http_log_exporter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/fixed_http_log_exporter.dart';

void main() {
  group('FixedHttpLogExporter', () {
    test('can be constructed with endpoint', () {
      final exporter = FixedHttpLogExporter(
        endpoint: 'http://localhost:4318',
      );
      expect(exporter, isNotNull);
    });

    test('appends /v1/logs to endpoint', () {
      final exporter = FixedHttpLogExporter(
        endpoint: 'http://localhost:4318',
      );
      // Verify via export to a non-existent server (should fail gracefully)
      expect(exporter, isNotNull);
    });

    test('export returns true for empty log list', () async {
      final exporter = FixedHttpLogExporter(
        endpoint: 'http://localhost:4318',
      );
      final result = await exporter.export([]);
      expect(result, isTrue);
    });

    test('export returns false after shutdown', () async {
      final exporter = FixedHttpLogExporter(
        endpoint: 'http://localhost:4318',
      );
      await exporter.shutdown();
      final result = await exporter.export([
        ScoutLogRecord(
          severityNumber: 9,
          severityText: 'INFO',
          body: 'test message',
          timestampNanos: BigInt.from(DateTime.now().microsecondsSinceEpoch) *
              BigInt.from(1000),
        ),
      ]);
      expect(result, isFalse);
    });

    test('shutdown is idempotent', () async {
      final exporter = FixedHttpLogExporter(
        endpoint: 'http://localhost:4318',
      );
      expect(await exporter.shutdown(), isTrue);
      expect(await exporter.shutdown(), isTrue);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/fixed_http_log_exporter_test.dart`
Expected: FAIL — `fixed_http_log_exporter.dart` doesn't exist

**Step 3: Write minimal implementation**

```dart
// lib/src/fixed_http_log_exporter.dart
// ignore_for_file: implementation_imports
import 'dart:math';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/collector/logs/v1/logs_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart'
    as common_pb;
import 'package:dartastic_opentelemetry/proto/logs/v1/logs.pb.dart'
    as logs_pb;
import 'package:dartastic_opentelemetry/proto/logs/v1/logs.pbenum.dart'
    as logs_enum;
import 'package:fixnum/fixnum.dart';
import 'package:dartastic_opentelemetry/src/metrics/export/otlp/metric_transformer.dart';
import 'package:http/http.dart' as http;

/// A log record to be exported.
class ScoutLogRecord {
  final int severityNumber;
  final String severityText;
  final String body;
  final BigInt timestampNanos;
  final Map<String, Object>? attributes;
  final String? traceId;
  final String? spanId;

  ScoutLogRecord({
    required this.severityNumber,
    required this.severityText,
    required this.body,
    required this.timestampNanos,
    this.attributes,
    this.traceId,
    this.spanId,
  });
}

/// OTLP HTTP log exporter following the same pattern as FixedHttpMetricExporter.
class FixedHttpLogExporter {
  final String _endpoint;
  final Map<String, String> _headers;
  final Duration _timeout;
  final int _maxRetries;
  final Duration _baseDelay;
  bool _isShutdown = false;
  final Random _random = Random();

  FixedHttpLogExporter({
    required String endpoint,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 3,
    Duration baseDelay = const Duration(milliseconds: 200),
  })  : _endpoint = endpoint.endsWith('/v1/logs')
            ? endpoint
            : '${endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint}/v1/logs',
        _headers = headers ?? {},
        _timeout = timeout,
        _maxRetries = maxRetries,
        _baseDelay = baseDelay;

  Future<bool> export(List<ScoutLogRecord> logs) async {
    if (_isShutdown) return false;
    if (logs.isEmpty) return true;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _tryExport(logs);
      } on http.ClientException catch (e) {
        if (attempt >= _maxRetries) return false;
        final isRetryable = _retryableStatusCodes.any(
          (code) => e.message.contains('status code $code'),
        );
        if (!isRetryable) return false;
        await Future<void>.delayed(_jitteredDelay(attempt));
      } catch (_) {
        if (attempt >= _maxRetries) return false;
        await Future<void>.delayed(_jitteredDelay(attempt));
      }
    }
    return false;
  }

  Future<bool> _tryExport(List<ScoutLogRecord> logs) async {
    final request = ExportLogsServiceRequest();
    final resourceLogs = logs_pb.ResourceLogs();

    final resource = OTel.defaultResource;
    if (resource != null) {
      resourceLogs.resource =
          MetricTransformer.transformResource(resource);
    }

    final scopeLogs = logs_pb.ScopeLogs();
    final scope = common_pb.InstrumentationScope();
    scope.name = 'scout_flutter';
    scope.version = '0.1.0';
    scopeLogs.scope = scope;

    for (final log in logs) {
      final record = logs_pb.LogRecord();
      record.timeUnixNano = Int64(log.timestampNanos.toInt());
      record.observedTimeUnixNano = Int64(log.timestampNanos.toInt());
      record.severityNumber =
          logs_enum.SeverityNumber.valueOf(log.severityNumber) ??
              logs_enum.SeverityNumber.SEVERITY_NUMBER_UNSPECIFIED;
      record.severityText = log.severityText;

      final bodyValue = common_pb.AnyValue();
      bodyValue.stringValue = log.body;
      record.body = bodyValue;

      if (log.attributes != null) {
        for (final entry in log.attributes!.entries) {
          final kv = common_pb.KeyValue();
          kv.key = entry.key;
          final val = common_pb.AnyValue();
          if (entry.value is String) {
            val.stringValue = entry.value as String;
          } else if (entry.value is int) {
            val.intValue = Int64(entry.value as int);
          } else if (entry.value is double) {
            val.doubleValue = entry.value as double;
          } else if (entry.value is bool) {
            val.boolValue = entry.value as bool;
          } else {
            val.stringValue = entry.value.toString();
          }
          kv.value = val;
          record.attributes.add(kv);
        }
      }

      scopeLogs.logRecords.add(record);
    }

    resourceLogs.scopeLogs.add(scopeLogs);
    request.resourceLogs.add(resourceLogs);

    final headers = Map<String, String>.from(_headers);
    headers['Content-Type'] = 'application/x-protobuf';

    final Uint8List bodyBytes = request.writeToBuffer();

    try {
      final response = await http
          .post(Uri.parse(_endpoint), headers: headers, body: bodyBytes)
          .timeout(_timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      throw http.ClientException(
        'Export failed with status code ${response.statusCode}',
      );
    } catch (e) {
      return false;
    }
  }

  Duration _jitteredDelay(int attempt) {
    final baseMs = _baseDelay.inMilliseconds;
    final delay = baseMs * pow(2, attempt);
    return Duration(
        milliseconds: (delay + _random.nextDouble() * delay).toInt());
  }

  static const _retryableStatusCodes = [429, 503];

  Future<bool> forceFlush() async => true;

  Future<bool> shutdown() async {
    _isShutdown = true;
    return true;
  }
}
```

**Step 4: Run tests**

Run: `flutter test test/fixed_http_log_exporter_test.dart`
Expected: All 5 tests PASS

Run: `flutter test`
Expected: All existing tests still PASS

**Step 5: Commit**

```bash
git add lib/src/fixed_http_log_exporter.dart test/fixed_http_log_exporter_test.dart
git commit -m "feat: add OTLP HTTP log exporter"
```

---

## Task 5: ScoutLogger — log API and print capture

**Files:**
- Create: `lib/src/scout_logger.dart`
- Test: `test/scout_logger_test.dart`

**Context:** Public API: `ScoutFlutter.log()`, `.logDebug()`, `.logInfo()`, `.logWarning()`, `.logError()`. Internally buffers log records and periodically flushes to `FixedHttpLogExporter`. Print capture via Zone override.

**Step 1: Write the failing test**

```dart
// test/scout_logger_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_logger.dart';

void main() {
  group('ScoutLogger', () {
    late ScoutLogger logger;
    late List<ScoutLogEntry> capturedLogs;

    setUp(() {
      capturedLogs = [];
      logger = ScoutLogger(
        onLog: (entry) => capturedLogs.add(entry),
      );
    });

    test('log records message with correct level', () {
      logger.log(LogLevel.info, 'test message');
      expect(capturedLogs, hasLength(1));
      expect(capturedLogs.first.level, LogLevel.info);
      expect(capturedLogs.first.message, 'test message');
    });

    test('logDebug uses debug level', () {
      logger.logDebug('debug msg');
      expect(capturedLogs.first.level, LogLevel.debug);
    });

    test('logInfo uses info level', () {
      logger.logInfo('info msg');
      expect(capturedLogs.first.level, LogLevel.info);
    });

    test('logWarning uses warning level', () {
      logger.logWarning('warn msg');
      expect(capturedLogs.first.level, LogLevel.warning);
    });

    test('logError uses error level', () {
      logger.logError('error msg');
      expect(capturedLogs.first.level, LogLevel.error);
    });

    test('log includes attributes when provided', () {
      logger.log(LogLevel.info, 'msg', attributes: {'key': 'value'});
      expect(capturedLogs.first.attributes, {'key': 'value'});
    });

    test('log includes timestamp', () {
      final before = DateTime.now();
      logger.log(LogLevel.info, 'msg');
      final after = DateTime.now();
      expect(capturedLogs.first.timestamp.isAfter(before) ||
          capturedLogs.first.timestamp.isAtSameMomentAs(before), isTrue);
      expect(capturedLogs.first.timestamp.isBefore(after) ||
          capturedLogs.first.timestamp.isAtSameMomentAs(after), isTrue);
    });

    test('LogLevel severity numbers match OTel spec', () {
      expect(LogLevel.debug.severityNumber, 5);
      expect(LogLevel.info.severityNumber, 9);
      expect(LogLevel.warning.severityNumber, 13);
      expect(LogLevel.error.severityNumber, 17);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/scout_logger_test.dart`
Expected: FAIL — `scout_logger.dart` doesn't exist

**Step 3: Write minimal implementation**

```dart
// lib/src/scout_logger.dart

enum LogLevel {
  debug(5, 'DEBUG'),
  info(9, 'INFO'),
  warning(13, 'WARN'),
  error(17, 'ERROR');

  final int severityNumber;
  final String severityText;
  const LogLevel(this.severityNumber, this.severityText);
}

class ScoutLogEntry {
  final LogLevel level;
  final String message;
  final DateTime timestamp;
  final Map<String, Object>? attributes;

  ScoutLogEntry({
    required this.level,
    required this.message,
    required this.timestamp,
    this.attributes,
  });
}

class ScoutLogger {
  final void Function(ScoutLogEntry entry) _onLog;

  ScoutLogger({required void Function(ScoutLogEntry entry) onLog})
      : _onLog = onLog;

  void log(LogLevel level, String message,
      {Map<String, Object>? attributes}) {
    _onLog(ScoutLogEntry(
      level: level,
      message: message,
      timestamp: DateTime.now(),
      attributes: attributes,
    ));
  }

  void logDebug(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.debug, message, attributes: attributes);

  void logInfo(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.info, message, attributes: attributes);

  void logWarning(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.warning, message, attributes: attributes);

  void logError(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.error, message, attributes: attributes);
}
```

**Step 4: Run tests**

Run: `flutter test test/scout_logger_test.dart`
Expected: All 8 tests PASS

**Step 5: Commit**

```bash
git add lib/src/scout_logger.dart test/scout_logger_test.dart
git commit -m "feat: add ScoutLogger with log levels and OTel severity mapping"
```

---

## Task 6: ScoutHttpOverrides + ScoutTrackingHttpClient — HTTP tracking and distributed tracing

**Files:**
- Create: `lib/src/scout_http_overrides.dart`
- Create: `lib/src/scout_tracking_http_client.dart`
- Test: `test/scout_http_overrides_test.dart`

**Context:** `ScoutHttpOverrides` replaces `HttpOverrides.global`, wrapping any existing overrides. `ScoutTrackingHttpClient` wraps every `HttpClient` and creates OTel spans per request. Injects W3C `traceparent` header for first-party hosts. Skips the OTLP endpoint and ignored URL patterns.

**Step 1: Write the failing test**

```dart
// test/scout_http_overrides_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_http_overrides.dart';

void main() {
  group('ScoutHttpOverrides', () {
    late HttpOverrides? originalOverrides;

    setUp(() {
      originalOverrides = HttpOverrides.current;
    });

    tearDown(() {
      HttpOverrides.global = originalOverrides;
    });

    test('wraps existing overrides', () {
      final overrides = ScoutHttpOverrides(
        existingOverrides: originalOverrides,
        exportEndpoint: 'http://localhost:4318',
        onRequestCompleted: (data) {},
      );
      HttpOverrides.global = overrides;

      final client = HttpClient();
      expect(client, isNotNull);
    });

    test('createHttpClient returns a client', () {
      final overrides = ScoutHttpOverrides(
        existingOverrides: null,
        exportEndpoint: 'http://localhost:4318',
        onRequestCompleted: (data) {},
      );

      final client = overrides.createHttpClient(null);
      expect(client, isNotNull);
    });
  });

  group('URL matching', () {
    test('shouldTrackUrl returns false for export endpoint', () {
      expect(
        shouldTrackUrl(
          Uri.parse('http://localhost:4318/v1/traces'),
          exportEndpoint: 'http://localhost:4318',
          ignorePatterns: null,
        ),
        isFalse,
      );
    });

    test('shouldTrackUrl returns false for ignored patterns', () {
      expect(
        shouldTrackUrl(
          Uri.parse('https://api.example.com/healthcheck'),
          exportEndpoint: 'http://localhost:4318',
          ignorePatterns: [RegExp(r'healthcheck')],
        ),
        isFalse,
      );
    });

    test('shouldTrackUrl returns true for normal URLs', () {
      expect(
        shouldTrackUrl(
          Uri.parse('https://api.example.com/users'),
          exportEndpoint: 'http://localhost:4318',
          ignorePatterns: null,
        ),
        isTrue,
      );
    });

    test('isFirstPartyHost matches exact host', () {
      expect(
        isFirstPartyHost('api.example.com', ['api.example.com']),
        isTrue,
      );
    });

    test('isFirstPartyHost matches wildcard', () {
      expect(
        isFirstPartyHost('api.example.com', ['*.example.com']),
        isTrue,
      );
    });

    test('isFirstPartyHost returns false for non-matching host', () {
      expect(
        isFirstPartyHost('api.other.com', ['*.example.com']),
        isFalse,
      );
    });

    test('isFirstPartyHost returns false for null list', () {
      expect(
        isFirstPartyHost('api.example.com', null),
        isFalse,
      );
    });
  });

  group('traceparent generation', () {
    test('generates valid W3C traceparent format', () {
      final tp = generateTraceparent('abc123', 'def456');
      expect(tp, '00-abc123-def456-01');
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/scout_http_overrides_test.dart`
Expected: FAIL — files don't exist

**Step 3: Write minimal implementation**

```dart
// lib/src/scout_http_overrides.dart
import 'dart:io';

import 'scout_tracking_http_client.dart';

/// Data collected from a completed HTTP request.
class HttpRequestData {
  final String method;
  final Uri url;
  final int statusCode;
  final int durationMs;
  final int responseSize;
  final String? error;

  HttpRequestData({
    required this.method,
    required this.url,
    required this.statusCode,
    required this.durationMs,
    required this.responseSize,
    this.error,
  });
}

/// HttpOverrides that wraps every HttpClient for tracking.
class ScoutHttpOverrides extends HttpOverrides {
  final HttpOverrides? existingOverrides;
  final String exportEndpoint;
  final List<RegExp>? ignorePatterns;
  final List<String>? firstPartyHosts;
  final void Function(HttpRequestData data) onRequestCompleted;

  ScoutHttpOverrides({
    this.existingOverrides,
    required this.exportEndpoint,
    this.ignorePatterns,
    this.firstPartyHosts,
    required this.onRequestCompleted,
  });

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = existingOverrides?.createHttpClient(context) ??
        super.createHttpClient(context);
    return ScoutTrackingHttpClient(
      inner: inner,
      exportEndpoint: exportEndpoint,
      ignorePatterns: ignorePatterns,
      firstPartyHosts: firstPartyHosts,
      onRequestCompleted: onRequestCompleted,
    );
  }
}

/// Check whether a URL should be tracked.
bool shouldTrackUrl(
  Uri url, {
  required String exportEndpoint,
  List<RegExp>? ignorePatterns,
}) {
  final urlStr = url.toString();

  // Skip the SDK's own export endpoint
  if (urlStr.startsWith(exportEndpoint)) return false;

  // Skip ignored patterns
  if (ignorePatterns != null) {
    for (final pattern in ignorePatterns) {
      if (pattern.hasMatch(urlStr)) return false;
    }
  }

  return true;
}

/// Check whether a host is in the first-party list.
bool isFirstPartyHost(String host, List<String>? firstPartyHosts) {
  if (firstPartyHosts == null || firstPartyHosts.isEmpty) return false;
  for (final pattern in firstPartyHosts) {
    if (pattern.startsWith('*.')) {
      final suffix = pattern.substring(1); // ".example.com"
      if (host.endsWith(suffix) || host == pattern.substring(2)) return true;
    } else {
      if (host == pattern) return true;
    }
  }
  return false;
}

/// Generate a W3C traceparent header value.
String generateTraceparent(String traceId, String spanId) {
  return '00-$traceId-$spanId-01';
}
```

```dart
// lib/src/scout_tracking_http_client.dart
import 'dart:io';
import 'dart:math';

import 'scout_http_overrides.dart';

/// An HttpClient wrapper that tracks requests.
class ScoutTrackingHttpClient implements HttpClient {
  final HttpClient _inner;
  final String exportEndpoint;
  final List<RegExp>? ignorePatterns;
  final List<String>? firstPartyHosts;
  final void Function(HttpRequestData data) onRequestCompleted;
  final Random _random = Random.secure();

  ScoutTrackingHttpClient({
    required HttpClient inner,
    required this.exportEndpoint,
    this.ignorePatterns,
    this.firstPartyHosts,
    required this.onRequestCompleted,
  }) : _inner = inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final track = shouldTrackUrl(url,
        exportEndpoint: exportEndpoint, ignorePatterns: ignorePatterns);

    if (!track) {
      return _inner.openUrl(method, url);
    }

    final stopwatch = Stopwatch()..start();
    final request = await _inner.openUrl(method, url);

    // Inject traceparent for first-party hosts
    if (isFirstPartyHost(url.host, firstPartyHosts)) {
      final traceId = _generateHex(32);
      final spanId = _generateHex(16);
      request.headers.set('traceparent', generateTraceparent(traceId, spanId));
    }

    return _TrackedHttpClientRequest(
      request,
      method: method,
      url: url,
      stopwatch: stopwatch,
      onCompleted: onRequestCompleted,
    );
  }

  String _generateHex(int length) {
    final bytes = List<int>.generate(length ~/ 2, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // Delegate all HttpClient methods to _inner, wrapping openUrl variants

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  // Delegate all property accessors and setters to _inner
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set maxConnectionsPerHost(int? value) =>
      _inner.maxConnectionsPerHost = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Wraps HttpClientRequest to intercept the response.
class _TrackedHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest _inner;
  final String method;
  final Uri url;
  final Stopwatch stopwatch;
  final void Function(HttpRequestData) onCompleted;

  _TrackedHttpClientRequest(
    this._inner, {
    required this.method,
    required this.url,
    required this.stopwatch,
    required this.onCompleted,
  });

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();
      stopwatch.stop();
      onCompleted(HttpRequestData(
        method: method,
        url: url,
        statusCode: response.statusCode,
        durationMs: stopwatch.elapsedMilliseconds,
        responseSize: response.contentLength,
      ));
      return response;
    } catch (e) {
      stopwatch.stop();
      onCompleted(HttpRequestData(
        method: method,
        url: url,
        statusCode: 0,
        durationMs: stopwatch.elapsedMilliseconds,
        responseSize: 0,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  // Delegate everything else to _inner
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  Future<HttpClientResponse> get done => _inner.done;
  @override
  String get method_ => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  Future flush() => _inner.flush();
}
```

Note: `_TrackedHttpClientRequest` has a `method_` getter (line with `get method_`) — check the actual Dart API. The `HttpClientRequest.method` getter returns a String. The wrapper delegates via `_inner.method`. Adjust if the Dart version uses a different name. This will be caught by `flutter analyze`.

**Step 4: Run tests and fix any issues**

Run: `flutter analyze`
Run: `flutter test test/scout_http_overrides_test.dart`
Expected: All tests PASS. Fix any compile errors from HttpClient interface (it's large).

**Step 5: Commit**

```bash
git add lib/src/scout_http_overrides.dart lib/src/scout_tracking_http_client.dart test/scout_http_overrides_test.dart
git commit -m "feat: add HTTP request tracking via HttpOverrides with distributed tracing"
```

---

## Task 7: ScoutDioInterceptor

**Files:**
- Create: `lib/src/scout_dio_interceptor.dart`
- Test: `test/scout_dio_interceptor_test.dart`
- Modify: `pubspec.yaml` — add `dio: ^5.0.0`

**Context:** Optional interceptor for Dio users with custom adapters. Default Dio users are already covered by HttpOverrides.

**Step 1: Add dio dependency**

Add to `pubspec.yaml` dependencies:
```yaml
  dio: ^5.0.0
```

Run: `flutter pub get`

**Step 2: Write the failing test**

```dart
// test/scout_dio_interceptor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_dio_interceptor.dart';
import 'package:scout_flutter/src/scout_http_overrides.dart';
import 'package:dio/dio.dart';

void main() {
  group('ScoutDioInterceptor', () {
    test('can be instantiated', () {
      final interceptor = ScoutDioInterceptor(
        onRequestCompleted: (data) {},
      );
      expect(interceptor, isNotNull);
    });

    test('stamps start time in request extras', () {
      final interceptor = ScoutDioInterceptor(
        onRequestCompleted: (data) {},
      );
      final options = RequestOptions(path: '/test');
      final handler = _MockRequestHandler();

      interceptor.onRequest(options, handler);

      expect(options.extra.containsKey('_scout_start_time'), isTrue);
      expect(handler.nexted, isTrue);
    });

    test('injects traceparent for first-party hosts', () {
      final interceptor = ScoutDioInterceptor(
        firstPartyHosts: ['api.example.com'],
        onRequestCompleted: (data) {},
      );
      final options = RequestOptions(
        path: '/test',
        baseUrl: 'https://api.example.com',
      );
      final handler = _MockRequestHandler();

      interceptor.onRequest(options, handler);

      expect(options.headers.containsKey('traceparent'), isTrue);
      expect(options.headers['traceparent'], matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')));
    });

    test('does not inject traceparent for non-first-party hosts', () {
      final interceptor = ScoutDioInterceptor(
        firstPartyHosts: ['api.example.com'],
        onRequestCompleted: (data) {},
      );
      final options = RequestOptions(
        path: '/test',
        baseUrl: 'https://other.com',
      );
      final handler = _MockRequestHandler();

      interceptor.onRequest(options, handler);

      expect(options.headers.containsKey('traceparent'), isFalse);
    });
  });
}

class _MockRequestHandler extends RequestInterceptorHandler {
  bool nexted = false;

  @override
  void next(RequestOptions requestOptions) {
    nexted = true;
  }
}
```

**Step 3: Run test to verify it fails**

Run: `flutter test test/scout_dio_interceptor_test.dart`
Expected: FAIL — `scout_dio_interceptor.dart` doesn't exist

**Step 4: Write minimal implementation**

```dart
// lib/src/scout_dio_interceptor.dart
import 'dart:math';

import 'package:dio/dio.dart';

import 'scout_http_overrides.dart';

/// Dio interceptor for HTTP request tracking.
///
/// Only needed when Dio is configured with a custom HttpClientAdapter.
/// Default Dio users are already covered by ScoutHttpOverrides.
class ScoutDioInterceptor extends Interceptor {
  static const _kStartTimeKey = '_scout_start_time';
  static const _kTraceIdKey = '_scout_trace_id';
  static const _kSpanIdKey = '_scout_span_id';

  final List<String>? firstPartyHosts;
  final void Function(HttpRequestData data) onRequestCompleted;
  final Random _random = Random.secure();

  ScoutDioInterceptor({
    this.firstPartyHosts,
    required this.onRequestCompleted,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStartTimeKey] = DateTime.now().millisecondsSinceEpoch;

    if (isFirstPartyHost(options.uri.host, firstPartyHosts)) {
      final traceId = _generateHex(32);
      final spanId = _generateHex(16);
      options.headers['traceparent'] = generateTraceparent(traceId, spanId);
      options.extra[_kTraceIdKey] = traceId;
      options.extra[_kSpanIdKey] = spanId;
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _report(response.requestOptions, statusCode: response.statusCode ?? 0);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _report(
      err.requestOptions,
      statusCode: err.response?.statusCode ?? 0,
      error: err.message,
    );
    handler.next(err);
  }

  void _report(
    RequestOptions options, {
    required int statusCode,
    String? error,
  }) {
    final startTime = options.extra[_kStartTimeKey] as int?;
    final durationMs = startTime != null
        ? DateTime.now().millisecondsSinceEpoch - startTime
        : 0;

    onRequestCompleted(HttpRequestData(
      method: options.method,
      url: options.uri,
      statusCode: statusCode,
      durationMs: durationMs,
      responseSize: 0,
      error: error,
    ));
  }

  String _generateHex(int length) {
    final bytes = List<int>.generate(length ~/ 2, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
```

**Step 5: Run tests**

Run: `flutter test test/scout_dio_interceptor_test.dart`
Expected: All 4 tests PASS

**Step 6: Commit**

```bash
git add pubspec.yaml lib/src/scout_dio_interceptor.dart test/scout_dio_interceptor_test.dart
git commit -m "feat: add optional Dio interceptor for HTTP tracking"
```

---

## Task 8: Exporter decorators — OfflineAware, BeforeSend, Sampled

**Files:**
- Create: `lib/src/offline_aware_span_exporter.dart`
- Test: `test/offline_aware_span_exporter_test.dart`

**Context:** Three decorator concerns wrap the base exporters:
1. **Sampled** — checks `SessionManager.isSampled`, returns true (no-op) if not sampled
2. **BeforeSend** — calls the user's callback, drops events that return null
3. **OfflineAware** — catches export failures, queues to OfflineQueue

These compose as: `Sampled(BeforeSend(OfflineAware(BaseExporter)))`.

For simplicity, we'll build a single `EnhancedSpanExporter` that combines all three concerns (since they're always used together). The same pattern applies to metrics and logs — but span export is the critical path, so we implement and test that first. Metrics and logs use the same wrapper pattern in the wiring task.

**Step 1: Write the failing test**

```dart
// test/offline_aware_span_exporter_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/offline_queue.dart';
import 'package:scout_flutter/src/offline_aware_span_exporter.dart';
import 'package:scout_flutter/src/session_manager.dart';

void main() {
  late Directory tempDir;
  late OfflineQueue queue;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scout_exporter_test_');
    queue = OfflineQueue(directory: tempDir, maxStorageMb: 1);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('EnhancedExporter', () {
    test('passes through when inner export succeeds', () async {
      var exported = false;
      final exporter = EnhancedExporter(
        innerExport: (_) async {
          exported = true;
          return true;
        },
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
      );

      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isTrue);
      expect(exported, isTrue);
    });

    test('returns true without exporting when not sampled', () async {
      var exported = false;
      final exporter = EnhancedExporter(
        innerExport: (_) async {
          exported = true;
          return true;
        },
        isSampled: () => false,
        queue: queue,
        signal: 'spans',
      );

      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isTrue);
      expect(exported, isFalse);
    });

    test('queues to offline when inner export fails', () async {
      final exporter = EnhancedExporter(
        innerExport: (_) async => false,
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
      );

      final result = await exporter.export([{'name': 'test'}]);
      expect(result, isFalse);

      // Verify it was queued
      final batches = await queue.dequeueAll();
      expect(batches, hasLength(1));
      expect(batches.first.signal, 'spans');
    });

    test('applies beforeSend filter', () async {
      final exported = <List<Map<String, dynamic>>>[];
      final exporter = EnhancedExporter(
        innerExport: (events) async {
          exported.add(events);
          return true;
        },
        isSampled: () => true,
        queue: queue,
        signal: 'spans',
        beforeSend: (event) {
          if (event['name'] == 'drop_me') return null;
          event['modified'] = true;
          return event;
        },
      );

      await exporter.export([
        {'name': 'keep_me'},
        {'name': 'drop_me'},
      ]);

      expect(exported.first, hasLength(1));
      expect(exported.first.first['name'], 'keep_me');
      expect(exported.first.first['modified'], isTrue);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `flutter test test/offline_aware_span_exporter_test.dart`
Expected: FAIL — file doesn't exist

**Step 3: Write minimal implementation**

```dart
// lib/src/offline_aware_span_exporter.dart
import 'offline_queue.dart';
import '../src/scout_rum_config.dart';

/// A composable exporter wrapper that adds sampling, beforeSend filtering,
/// and offline queueing to any export function.
class EnhancedExporter {
  final Future<bool> Function(List<Map<String, dynamic>> events) innerExport;
  final bool Function() isSampled;
  final OfflineQueue queue;
  final String signal;
  final BeforeSendCallback? beforeSend;

  EnhancedExporter({
    required this.innerExport,
    required this.isSampled,
    required this.queue,
    required this.signal,
    this.beforeSend,
  });

  Future<bool> export(List<Map<String, dynamic>> events) async {
    if (!isSampled()) return true;
    if (events.isEmpty) return true;

    // Apply beforeSend filter
    final filtered = <Map<String, dynamic>>[];
    for (final event in events) {
      final mapped = {...event, 'type': signal};
      final result = beforeSend != null ? beforeSend!(mapped) : mapped;
      if (result != null) {
        filtered.add(result);
      }
    }

    if (filtered.isEmpty) return true;

    final success = await innerExport(filtered);
    if (!success) {
      // Queue for later retry
      await queue.enqueue(signal, filtered);
    }
    return success;
  }
}
```

**Step 4: Run tests**

Run: `flutter test test/offline_aware_span_exporter_test.dart`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add lib/src/offline_aware_span_exporter.dart test/offline_aware_span_exporter_test.dart
git commit -m "feat: add EnhancedExporter with sampling, beforeSend, and offline queueing"
```

---

## Task 9: Wire everything into initialize() + barrel exports

**Files:**
- Modify: `lib/src/scout_rum.dart` — integrate all Phase 3 components
- Modify: `lib/scout_flutter.dart` — update barrel exports
- Test: verify all existing tests still pass + `flutter analyze` clean

**Context:** This is the integration task. Wire SessionManager, HttpOverrides, ScoutLogger, OfflineQueue, and EnhancedExporter into `ScoutFlutter.initialize()`. Add public APIs for `sessionId`, `log()`, `dioInterceptor`.

**Step 1: Update barrel exports**

In `lib/scout_flutter.dart`, add:
```dart
export 'src/scout_rum.dart';
export 'src/scout_rum_config.dart';
export 'src/user_action_annotation.dart';
export 'src/scout_logger.dart' show LogLevel;
export 'src/scout_dio_interceptor.dart';
```

**Step 2: Update ScoutFlutter class in `lib/src/scout_rum.dart`**

Add imports:
```dart
import 'dart:async';

import 'package:path_provider/path_provider.dart';

import 'session_manager.dart';
import 'scout_logger.dart';
import 'scout_http_overrides.dart';
import 'fixed_http_log_exporter.dart';
import 'offline_queue.dart';
import 'offline_aware_span_exporter.dart';
import 'scout_dio_interceptor.dart';
```

Add static fields:
```dart
  static SessionManager? _sessionManager;
  static ScoutLogger? _logger;
  static FixedHttpLogExporter? _logExporter;
  static OfflineQueue? _offlineQueue;
  static Timer? _offlineFlushTimer;
  static ScoutDioInterceptor? _dioInterceptor;
```

Add public getters:
```dart
  /// Current session ID.
  static String? get sessionId => _sessionManager?.sessionId;

  /// Dio interceptor for custom Dio adapter users.
  /// Only needed if Dio uses a non-default HttpClientAdapter.
  static ScoutDioInterceptor get dioInterceptor {
    _dioInterceptor ??= ScoutDioInterceptor(
      firstPartyHosts: _config?.firstPartyHosts,
      onRequestCompleted: _onHttpRequestCompleted,
    );
    return _dioInterceptor!;
  }
```

Add logging methods:
```dart
  /// Log a structured message.
  static void log(LogLevel level, String message,
      {Map<String, Object>? attributes}) {
    _logger?.log(level, message, attributes: attributes);
  }

  /// Log a debug message.
  static void logDebug(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.debug, message, attributes: attributes);

  /// Log an info message.
  static void logInfo(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.info, message, attributes: attributes);

  /// Log a warning message.
  static void logWarning(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.warning, message, attributes: attributes);

  /// Log an error message.
  static void logError(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.error, message, attributes: attributes);
```

In `initialize()`, after `_config = config;`, add:

```dart
    // --- Phase 3: Session, Logging, Network, Offline ---

    // 1. Session manager
    _sessionManager = SessionManager(
      sampleRate: config.sessionSampleRate,
      timeoutMinutes: config.sessionTimeoutMinutes,
    );

    // 2. Offline queue
    final tempDir = await getTemporaryDirectory();
    final offlineDir = Directory('${tempDir.path}/scout_offline');
    _offlineQueue = OfflineQueue(
      directory: offlineDir,
      maxStorageMb: config.maxOfflineStorageMb,
    );

    // 3. Periodic offline flush (every 60 seconds)
    _offlineFlushTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _flushOfflineQueue(),
    );

    // 4. Structured logging
    if (config.enableLogging) {
      _logExporter = FixedHttpLogExporter(
        endpoint: httpEndpoint,
        headers: config.headers,
      );
      _logger = ScoutLogger(
        onLog: _onLogEntry,
      );
    }

    // 5. HTTP tracking via HttpOverrides
    if (config.enableNetworkTracking) {
      final existingOverrides = HttpOverrides.current;
      HttpOverrides.global = ScoutHttpOverrides(
        existingOverrides: existingOverrides,
        exportEndpoint: httpEndpoint,
        ignorePatterns: config.ignoreUrlPatterns,
        firstPartyHosts: config.firstPartyHosts,
        onRequestCompleted: _onHttpRequestCompleted,
      );
    }
```

Update `_setupLifecycleTracking()` to include session rotation:

```dart
      onPause: () {
        addBreadcrumb('lifecycle', 'app_paused');
        _sessionManager?.onBackground();
      },
      onResume: () {
        addBreadcrumb('lifecycle', 'app_resumed');
        _sessionManager?.onForeground();
        // ...existing warm start code...
      },
```

Add helper methods:

```dart
  static void _onHttpRequestCompleted(HttpRequestData data) {
    if (!isInitialized) return;
    if (!(_sessionManager?.isSampled ?? true)) return;

    final span = FlutterOTel.tracer.startSpan(
      'http.request',
      attributes: <String, Object>{
        'http.method': data.method,
        'http.url': data.url.toString(),
        'http.status_code': data.statusCode,
        'http.response_content_length': data.responseSize,
        'http.duration_ms': data.durationMs,
        if (data.error != null) 'http.error': data.error!,
        'session.id': _sessionManager?.sessionId ?? '',
        ..._commonAttributes(),
      }.toAttributes(),
    );
    if (data.error != null) {
      span.setStatus(StatusCode.error, data.error!);
    }
    span.end();
  }

  static void _onLogEntry(ScoutLogEntry entry) {
    if (!(_sessionManager?.isSampled ?? true)) return;
    final logRecord = ScoutLogRecord(
      severityNumber: entry.level.severityNumber,
      severityText: entry.level.severityText,
      body: entry.message,
      timestampNanos: BigInt.from(
              entry.timestamp.microsecondsSinceEpoch) *
          BigInt.from(1000),
      attributes: {
        'session.id': _sessionManager?.sessionId ?? '',
        if (_navObserver?.currentScreenName != null)
          'screen.name': _navObserver!.currentScreenName!,
        if (_userId != null) 'enduser.id': _userId!,
        ...?entry.attributes,
      },
    );
    _logExporter?.export([logRecord]);
  }

  static Future<void> _flushOfflineQueue() async {
    if (_offlineQueue == null) return;
    final batches = await _offlineQueue!.dequeueAll();
    for (final batch in batches) {
      // Re-export based on signal type
      // For now, just drop re-exported data on failure (don't re-queue to avoid loops)
      // Future: implement proper per-signal re-export
    }
  }
```

Add `session.id` to `_commonAttributes()`:

```dart
  static Map<String, Object> _commonAttributes() {
    return {
      if (_userId != null) 'enduser.id': _userId!,
      if (_userEmail != null) 'enduser.email': _userEmail!,
      if (_connectivityType != 'unknown')
        'network.connection.type': _connectivityType,
      if (_sessionManager != null) 'session.id': _sessionManager!.sessionId,
    };
  }
```

Update `resetForTesting()`:

```dart
    _sessionManager = null;
    _logger = null;
    _logExporter = null;
    _offlineQueue = null;
    _offlineFlushTimer?.cancel();
    _offlineFlushTimer = null;
    _dioInterceptor = null;
```

**Step 3: Run flutter analyze**

Run: `flutter analyze`
Expected: No issues (fix any that appear)

**Step 4: Run all tests**

Run: `flutter test`
Expected: All tests PASS (existing + new)

**Step 5: Commit**

```bash
git add lib/src/scout_rum.dart lib/scout_flutter.dart
git commit -m "feat: wire Phase 3 components into initialize — network tracking, sessions, logging, offline queue"
```

---

## Dependency Summary

Add to `pubspec.yaml`:
```yaml
  path_provider: ^2.1.0
  dio: ^5.0.0
```

These are added in Tasks 3 and 7 respectively.

## Import Notes

The `FixedHttpLogExporter` uses `implementation_imports` like `FixedHttpMetricExporter`:
```dart
// ignore_for_file: implementation_imports
```
This is needed for `MetricTransformer.transformResource()`. The log exporter uses it for resource transformation only.

The log protobuf imports are:
```dart
import 'package:dartastic_opentelemetry/proto/collector/logs/v1/logs_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/logs/v1/logs.pb.dart' as logs_pb;
import 'package:dartastic_opentelemetry/proto/logs/v1/logs.pbenum.dart' as logs_enum;
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart' as common_pb;
```

These are publicly available in the `proto/` directory of dartastic_opentelemetry (no `implementation_imports` needed for proto files).

## Testing Strategy

Each task has unit tests for its component. Integration testing (real HTTP requests, real OTel export) should be done manually on a device with the OTel collector, same as Phase 2 — not automated in unit tests.

## File Creation Order

1. `lib/src/session_manager.dart` + `test/session_manager_test.dart`
2. Modify `lib/src/scout_rum_config.dart` + `test/scout_rum_config_test.dart`
3. `lib/src/offline_queue.dart` + `test/offline_queue_test.dart`
4. `lib/src/fixed_http_log_exporter.dart` + `test/fixed_http_log_exporter_test.dart`
5. `lib/src/scout_logger.dart` + `test/scout_logger_test.dart`
6. `lib/src/scout_http_overrides.dart` + `lib/src/scout_tracking_http_client.dart` + `test/scout_http_overrides_test.dart`
7. `lib/src/scout_dio_interceptor.dart` + `test/scout_dio_interceptor_test.dart`
8. `lib/src/offline_aware_span_exporter.dart` + `test/offline_aware_span_exporter_test.dart`
9. Modify `lib/src/scout_rum.dart` + `lib/scout_flutter.dart`
