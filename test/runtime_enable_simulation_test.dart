import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' show OTel;
import 'package:dartastic_opentelemetry/proto/collector/logs/v1/logs_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/collector/trace/v1/trace_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

/// End-to-end check of the runtime kill switch through the real
/// `ScoutFlutter.initialize()` against a dummy OTLP collector, modelled on
/// the customer case: a 24/7 app whose process is force-woken outside
/// working hours and decides `enabled` from its own cached schedule.
///
/// Standalone scenarios use the real OTLP/HTTP exporters, so "nothing left
/// the device" is asserted as "the collector received zero requests". A
/// hybrid scenario runs against a fake native owner on the method channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Collector collector;
  late Directory docs;
  const native = MethodChannel('com.base14.scout_flutter');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    HttpOverrides.global = null; // talk to a real local server
    collector = await _Collector.start();
    docs = await Directory.systemTemp.createTemp('scout_enable_sim');
    messenger.setMockMethodCallHandler(pathProvider, (call) async => docs.path);
  });

  tearDown(() async {
    ScoutFlutter.resetForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    await OTel.reset();
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    await collector.close();
    await docs.delete(recursive: true);
  });

  ScoutFlutterConfig config({
    required bool enabled,
    int exportIntervalSeconds = 1,
  }) => ScoutFlutterConfig(
    serviceName: 'enable-sim',
    endpoint: collector.baseUrl,
    secure: false,
    sessionSampleRate: 100,
    exportIntervalSeconds: exportIntervalSeconds,
    enabled: enabled,
    enableErrorTracking: false, // leave flutter_test's error handlers alone
    enableAutoTapTracking: false,
    enableLifecycleTracking: false,
    enableStartupTracking: false,
    enableConnectivityTracking: false,
    enableNetworkTracking: false,
    enableLongTaskDetection: false,
    enableAnrDetection: false,
    enablePerformanceMetrics: false,
  );

  /// A work-hours schedule the app cached from its own backend: RUM is on
  /// from 1h before the shift starts until the shift ends.
  bool rumWindow(DateTime now, {required int shiftStart, required int end}) =>
      now.hour >= shiftStart - 1 && now.hour < end;

  /// Every kind of signal, errors included (alwaysCaptureErrors is on).
  void activity(String marker) {
    ScoutFlutter.logEvent('screen_view', attributes: {'marker': marker});
    ScoutFlutter.logEvent('error', attributes: {'marker': marker});
    ScoutFlutter.reportError(StateError(marker), StackTrace.current);
    ScoutFlutter.logInfo('log $marker', attributes: {'marker': marker});
    ScoutFlutter.logError('err $marker', attributes: {'marker': marker});
  }

  void standaloneNative({List<Map<String, Object>> exitInfo = const []}) {
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'initNativeDelegate':
          return false; // Dart exports
        case 'getExitInfoReports':
          return exitInfo;
        default:
          return null;
      }
    });
  }

  File sessionFile() => File('${docs.path}/scout_session.json');
  File crashMarker() => File('${docs.path}/scout_crash/session_marker.json');

  test('standalone: a wake-up outside the RUM window sends zero requests and '
      'counts no session', () async {
    standaloneNative();
    // A session from the previous evening is still within its idle window.
    final persisted = jsonEncode({
      'v': 1,
      'id': 'yesterday',
      'startedAt': DateTime.now().millisecondsSinceEpoch - 60000,
      'lastActiveAt': DateTime.now().millisecondsSinceEpoch - 30000,
      'sampled': true,
      'samplingSource': 'fallback',
    });
    await sessionFile().writeAsString(persisted);

    // WorkManager wakes the process at 03:00; the shift starts at 09:00.
    final wake = DateTime(2026, 11, 12, 3);
    final enabled = rumWindow(wake, shiftStart: 9, end: 18);
    expect(enabled, isFalse);

    ScoutFlutter.initialize(config: config(enabled: enabled));
    activity('early'); // during the bootstrap
    await initialized();
    expect(ScoutFlutter.isEnabled, isFalse);
    expect(ScoutFlutter.sessionId, isNull);
    expect(ScoutFlutter.sessionSamplingDecision, isNull);

    activity('night');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(collector.requests, 0, reason: 'no OTLP request while disabled');
    expect(
      sessionFile().readAsStringSync(),
      persisted,
      reason: 'the persisted session is neither resumed nor touched',
    );
    expect(crashMarker().existsSync(), isFalse);

    // 08:00: the app's schedule turns RUM on in the same process.
    ScoutFlutter.setEnabled(true);
    final fresh = ScoutFlutter.sessionId;
    expect(fresh, isNotNull);
    expect(fresh, isNot('yesterday'), reason: 'always a fresh session');
    activity('shift');
    await collector.awaitSpan('shift', 'screen_view');
    await collector.awaitLog('shift');
    expect(collector.span('shift', 'screen_view')['session.id'], fresh);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(collector.marked('early'), isEmpty);
    expect(collector.marked('night'), isEmpty);
  });

  test(
    'standalone: disabling flushes what was recorded, ends the session, then '
    'drops everything; enabling starts a new session',
    () async {
      standaloneNative();
      // A long export interval: anything arriving quickly was flushed.
      ScoutFlutter.initialize(
        config: config(enabled: true, exportIntervalSeconds: 30),
      );
      await initialized();
      final first = ScoutFlutter.sessionId!;
      await until(() => crashMarker().existsSync());

      activity('before');
      ScoutFlutter.setEnabled(false);
      expect(ScoutFlutter.sessionId, isNull);
      await collector.awaitSpan('before', 'screen_view');
      await collector.awaitLog('before');
      expect(collector.span('before', 'screen_view')['session.id'], first);
      await pumpChannel();
      expect(sessionFile().existsSync(), isFalse, reason: 'session ended');
      expect(crashMarker().existsSync(), isFalse);

      final afterFlush = collector.requests;
      activity('off');
      ScoutFlutter.setEnabled(false); // a repeat is a no-op: no flush
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(collector.requests, afterFlush);

      ScoutFlutter.setEnabled(true);
      final second = ScoutFlutter.sessionId!;
      expect(second, isNot(first));
      ScoutFlutter.setEnabled(true); // no-op: same session
      expect(ScoutFlutter.sessionId, second);
      await pumpChannel();
      expect(crashMarker().existsSync(), isTrue);
      activity('back');
      ScoutFlutter.setEnabled(false); // flushes 'back'
      await collector.awaitSpan('back', 'screen_view');
      expect(collector.span('back', 'screen_view')['session.id'], second);
      expect(collector.marked('off'), isEmpty);
    },
  );

  test(
    'standalone: a setEnabled before initialize wins over the config',
    () async {
      standaloneNative();
      ScoutFlutter.setEnabled(false);
      ScoutFlutter.initialize(config: config(enabled: true));
      await initialized();
      expect(ScoutFlutter.isEnabled, isFalse);
      activity('held');
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(collector.requests, 0);
    },
  );

  test(
    'standalone: a setEnabled while the bootstrap runs is applied',
    () async {
      standaloneNative();
      ScoutFlutter.initialize(config: config(enabled: false));
      ScoutFlutter.setEnabled(true);
      await initialized();
      await pumpChannel();
      expect(ScoutFlutter.sessionId, isNotNull);
      activity('boot-on');
      await collector.awaitSpan('boot-on', 'screen_view');
    },
  );

  test(
    'standalone: a crash while disabled is never replayed; an enabled run\'s '
    'crash waits for the next enabled point',
    () async {
      final disabledSince = DateTime.now().millisecondsSinceEpoch;
      final anrEnabledRun = {
        'crash_type': 'anr',
        'crash_reason': 'enabled-run',
        'crash_death_timestamp_ms': disabledSince - 60000,
      };
      final anrDisabledRun = {
        'crash_type': 'anr',
        'crash_reason': 'disabled-run',
        'crash_death_timestamp_ms': disabledSince + 1000,
      };

      // Launch 1, enabled: the process dies without a clean pause.
      standaloneNative();
      ScoutFlutter.initialize(config: config(enabled: true));
      await initialized();
      // isInitialized turns true before the bootstrap writes the marker.
      await until(() => crashMarker().existsSync());
      await pumpChannel();
      final crashedSession = ScoutFlutter.sessionId;
      ScoutFlutter.resetForTesting();
      // ignore: invalid_use_of_visible_for_testing_member
      await OTel.reset();

      // Launch 2, disabled: the enabled run's crash is kept, and this
      // launch also dies (exit-info records an ANR after disabledSince).
      standaloneNative();
      ScoutFlutter.initialize(config: config(enabled: false));
      await initialized();
      final stored = File('${docs.path}/scout_disabled_since');
      await until(stored.existsSync);
      await pumpChannel();
      await stored.writeAsString('$disabledSince'); // pin for determinism
      expect(crashMarker().existsSync(), isTrue, reason: 'kept, not checked');
      ScoutFlutter.resetForTesting();
      // ignore: invalid_use_of_visible_for_testing_member
      await OTel.reset();

      // Launch 3, disabled at start, enabled later.
      // Launch 1's pipeline flushed its own spans when it shut down.
      final before = collector.requests;
      standaloneNative(exitInfo: [anrEnabledRun, anrDisabledRun]);
      ScoutFlutter.initialize(config: config(enabled: false));
      await initialized();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(collector.requests, before, reason: 'launch 3 is disabled');
      ScoutFlutter.setEnabled(true);
      await collector.awaitSpan(null, 'app_crash');
      await collector.awaitSpan(null, 'native_crash');
      expect(
        collector.unmarked('app_crash').single['crash.previous_session_id'],
        crashedSession,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final reasons = collector
          .unmarked('native_crash')
          .map((s) => s['crash.reason']);
      expect(reasons, ['enabled-run']);
      expect(stored.existsSync(), isFalse, reason: 'cleared once enabled');
    },
  );

  test(
    'standalone: disabling mid-session means an unclean exit is no crash',
    () async {
      standaloneNative();
      ScoutFlutter.initialize(config: config(enabled: true));
      await initialized();
      ScoutFlutter.setEnabled(false);
      await pumpChannel();
      ScoutFlutter.resetForTesting(); // the process dies while disabled
      // ignore: invalid_use_of_visible_for_testing_member
      await OTel.reset();

      standaloneNative();
      ScoutFlutter.initialize(config: config(enabled: true));
      await initialized();
      ScoutFlutter.setEnabled(false); // flush whatever was queued
      await pumpChannel();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(collector.unmarked('app_crash'), isEmpty);
    },
  );

  test(
    'hybrid: forwards enabled to the native owner and follows its session',
    () async {
      final owner = _FakeNativeOwner();
      messenger.setMockMethodCallHandler(native, owner.handle);

      ScoutFlutter.initialize(config: config(enabled: false));
      await initialized();
      expect(owner.initEnabled, isFalse, reason: 'passed into native config');
      expect(ScoutFlutter.sessionId, isNull);
      ScoutFlutter.setUser(id: 'expert-7'); // identity is still recorded
      activity('night');
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(owner.ingested, isEmpty, reason: 'nothing bridged to the owner');
      expect(collector.requests, 0);
      expect(owner.userId, 'expert-7');

      ScoutFlutter.setEnabled(true);
      await pumpChannel();
      expect(owner.calls, ['setEnabled(true)']);
      expect(ScoutFlutter.sessionId, owner.sessionId);
      expect(owner.sessionId, isNot('native-1'), reason: 'fresh session');
      activity('shift');
      await owner.awaitIngest('shift');

      ScoutFlutter.setEnabled(true); // no-op: nothing forwarded
      await pumpChannel();
      expect(owner.calls, ['setEnabled(true)']);

      owner.ingested.clear();
      activity('last');
      ScoutFlutter.setEnabled(false);
      await pumpChannel();
      expect(owner.calls, ['setEnabled(true)', 'setEnabled(false)']);
      expect(
        owner.spansAtDisable.any((p) => p.contains('last')),
        isTrue,
        reason: 'spans flushed to the owner before it was told to stop',
      );
      expect(ScoutFlutter.sessionId, isNull);
      expect(collector.requests, 0);
    },
  );
}

/// Waits for the asynchronous bootstrap to finish (tracer and exporters up).
Future<void> initialized() async {
  final sw = Stopwatch()..start();
  while (!ScoutFlutter.isInitialized &&
      sw.elapsed < const Duration(seconds: 15)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(ScoutFlutter.isInitialized, isTrue, reason: 'bootstrap stalled');
  await ScoutFlutter.refreshSessionIdentity();
}

Future<void> until(bool Function() cond) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsed < const Duration(seconds: 15)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(cond(), isTrue, reason: 'condition not reached');
}

Future<void> pumpChannel() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

/// A native owner that follows the kill switch like scout-core: no session
/// while disabled, a fresh one on every enable.
class _FakeNativeOwner {
  bool enabled = true;
  bool? initEnabled;
  int sessions = 1;
  String? userId;
  final calls = <String>[];
  final ingested = <String>[];
  final spanPayloads = <String>[];

  /// Span payloads the owner had received when it was told to stop.
  List<String> spansAtDisable = const [];

  String get sessionId => 'native-$sessions';

  Future<void> awaitIngest(String marker) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 15)) {
      if (ingested.any((p) => p.contains(marker))) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('timed out waiting for $marker at the owner');
  }

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'initNativeDelegate':
        initEnabled = args['enabled'] as bool?;
        enabled = initEnabled ?? true;
        return true;
      case 'setEnabled':
        final v = args['value'] as bool;
        calls.add('setEnabled($v)');
        if (v && !enabled) sessions++;
        if (!v) spansAtDisable = List.of(spanPayloads);
        enabled = v;
        return null;
      case 'getSessionIdentity':
        if (!enabled) return null;
        return {
          'sessionId': sessionId,
          'anonymousId': 'anon',
          'sampled': true,
          'samplingSource': 'fallback',
        };
      case 'setUser':
        userId = args['id'] as String?;
        return null;
      case 'ingestSpans':
        spanPayloads.add(args['json'] as String);
        ingested.add(args['json'] as String);
        return null;
      case 'ingestLogs':
      case 'ingestMetrics':
        ingested.add(args['json'] as String);
        return null;
      default:
        return null;
    }
  }
}

/// OTLP/protobuf sink that counts every request it receives.
class _Collector {
  _Collector._(this._server);
  final HttpServer _server;
  int requests = 0;
  final _spans = <Map<String, String>>[];
  final _logs = <Map<String, String>>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_Collector> start() async {
    final c = _Collector._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    c._server.listen(c._handle);
    return c;
  }

  Future<void> _handle(HttpRequest req) async {
    requests++;
    final path = req.uri.path;
    final bytes = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    try {
      if (path.endsWith('/v1/traces')) {
        final r = ExportTraceServiceRequest.fromBuffer(bytes);
        for (final rs in r.resourceSpans) {
          for (final ss in rs.scopeSpans) {
            for (final sp in ss.spans) {
              _spans.add({'@name': sp.name, ..._attrs(sp.attributes)});
            }
          }
        }
      }
      if (path.endsWith('/v1/logs')) {
        final r = ExportLogsServiceRequest.fromBuffer(bytes);
        for (final rl in r.resourceLogs) {
          for (final sl in rl.scopeLogs) {
            for (final lr in sl.logRecords) {
              _logs.add(_attrs(lr.attributes));
            }
          }
        }
      }
    } catch (_) {}
    req.response.statusCode = 200;
    req.response.write('{}');
    await req.response.close();
  }

  List<Map<String, String>> spans(String? marker, String name) =>
      _spans.where((s) => s['marker'] == marker && s['@name'] == name).toList();
  Map<String, String> span(String marker, String name) =>
      spans(marker, name).single;
  List<Map<String, String>> unmarked(String name) => spans(null, name);

  /// Every span and log carrying [marker].
  List<Map<String, String>> marked(String marker) => [
    ..._spans.where((s) => s['marker'] == marker),
    ..._logs.where((l) => l['marker'] == marker),
  ];

  Future<void> awaitSpan(String? marker, String name) =>
      _await('span $name/$marker', () => spans(marker, name).isNotEmpty);
  Future<void> awaitLog(String marker) =>
      _await('log $marker', () => _logs.any((l) => l['marker'] == marker));

  Future<void> _await(String what, bool Function() cond) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 15)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('timed out waiting for $what');
  }

  Future<void> close() => _server.close(force: true);

  static Map<String, String> _attrs(List<KeyValue> kvs) => {
    for (final kv in kvs)
      kv.key: switch (kv.value) {
        final v when v.hasStringValue() => v.stringValue,
        final v when v.hasBoolValue() => '${v.boolValue}',
        final v when v.hasIntValue() => '${v.intValue}',
        final v when v.hasDoubleValue() => '${v.doubleValue}',
        final v => v.toString(),
      },
  };
}
