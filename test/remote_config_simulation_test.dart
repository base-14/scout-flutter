import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' show OTel;
import 'package:dartastic_opentelemetry/proto/collector/logs/v1/logs_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/collector/trace/v1/trace_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

/// End-to-end check of user-based sampling through the real
/// `ScoutFlutter.initialize()` (standalone mode: real OTLP/HTTP exporters)
/// against a production-like setup:
///
/// - A dummy remote-config server applies per-user targeting rules and serves
///   `scout_user_sampling` over HTTP. Rules can be re-published mid-test, like
///   a console publish.
/// - The app-side client works like Firebase Remote Config: it fetches,
///   caches the last-fetched value in the app's own storage, and reads that
///   cached value synchronously at startup.
/// - The same server is the OTLP collector, so assertions are on what the SDK
///   actually exported.
///
/// A second scenario runs delegated (hybrid) mode against a fake native
/// owner on the method channel, and checks that the Flutter layer forwards
/// to the owner and follows the owner's decision.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;
  late Directory docs;
  const native = MethodChannel('com.base14.scout_flutter');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    // flutter_test answers every HTTP request with 400; this test talks to a
    // real local server.
    HttpOverrides.global = null;
    backend = await _Backend.start();
    docs = await Directory.systemTemp.createTemp('scout_rc_sim');
    messenger.setMockMethodCallHandler(pathProvider, (call) async => docs.path);
  });

  tearDown(() async {
    ScoutFlutter.resetForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    await OTel.reset(); // each test is a fresh "launch"; OTel allows one init per process
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    await backend.close();
    await docs.delete(recursive: true);
  });

  ScoutFlutterConfig config({bool? userSampling}) => ScoutFlutterConfig(
    serviceName: 'rc-sim',
    endpoint: backend.baseUrl,
    secure: false,
    sessionSampleRate:
        100, // fallback keeps everything, so any drop is the user value
    exportIntervalSeconds: 1,
    userSampling: userSampling,
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

  Future<void> activity(String marker) async {
    ScoutFlutter.logEvent('screen_view', attributes: {'marker': marker});
    ScoutFlutter.logEvent('error', attributes: {'marker': marker});
    ScoutFlutter.logInfo('log $marker', attributes: {'marker': marker});
  }

  test('standalone: remote config drives per-user sessions end to end', () async {
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'initNativeDelegate') return false; // Dart exports
      return null;
    });
    backend.publish({'alice': false, 'bob': false, 'carol': true});
    final rc = _AppRemoteConfig(backend.baseUrl, File('${docs.path}/app_rc'));

    // ── Fresh install: nothing cached, so no opinion. Fallback session.
    ScoutFlutter.initialize(config: config(userSampling: rc.cachedValue()));
    await initialized();
    final anon = ScoutFlutter.sessionId;
    await activity('anon');
    await backend.awaitSpan('anon', 'screen_view');
    expect(
      backend.span('anon', 'screen_view')['session.sampling_source'],
      'fallback',
    );

    // alice logs in: anonymous → first id keeps the session.
    ScoutFlutter.setUserSampling(await rc.fetch('alice'));
    ScoutFlutter.setUser(id: 'alice');
    expect(ScoutFlutter.sessionId, anon);
    expect(ScoutFlutter.sessionSamplingDecision?.source, 'fallback');

    // ── Account switch alice → bob ("no"): bob's value first, then setUser,
    // which starts a new user-decided session. Spans stop; errors and logs flow.
    ScoutFlutter.setUserSampling(await rc.fetch('bob'));
    ScoutFlutter.setUser(id: 'bob');
    expect(ScoutFlutter.sessionId, isNot(anon));
    final bobSession = ScoutFlutter.sessionId;
    expect(ScoutFlutter.sessionSamplingDecision, (
      sampled: false,
      source: 'user',
    ));
    await activity('bob-no');
    await backend.awaitSpan('bob-no', 'error');
    await backend.awaitLog('bob-no');
    expect(backend.spans('bob-no', 'screen_view'), isEmpty);
    final log = backend.log('bob-no');
    expect(log['session.id'], bobSession);
    expect(log['session.sampling_source'], 'user');
    expect(log['session.sampled'], 'false');

    // ── The console moves bob to "yes"; a refresh mid-session must not change
    // the current session.
    backend.publish({'alice': false, 'bob': true, 'carol': true});
    ScoutFlutter.setUserSampling(await rc.fetch('bob'));
    await activity('bob-refresh');
    await backend.awaitSpan('bob-refresh', 'error');
    await backend.awaitLog('bob-refresh');
    expect(backend.spans('bob-refresh', 'screen_view'), isEmpty);
    expect(ScoutFlutter.sessionId, bobSession);

    // ── Account switch bob → carol ("yes"): a new session with spans flowing.
    ScoutFlutter.setUserSampling(await rc.fetch('carol'));
    ScoutFlutter.setUser(id: 'carol');
    expect(ScoutFlutter.sessionId, isNot(bobSession));
    await activity('carol-yes');
    await backend.awaitSpan('carol-yes', 'screen_view');
    expect(
      backend.span('carol-yes', 'screen_view')['session.sampling_source'],
      'user',
    );

    // ── Logout: clearUser resets the value and rotates into a fallback session.
    final beforeLogout = ScoutFlutter.sessionId;
    ScoutFlutter.clearUser();
    rc.clear();
    expect(ScoutFlutter.sessionId, isNot(beforeLogout));
    await activity('logged-out');
    await backend.awaitSpan('logged-out', 'screen_view');
    expect(
      backend.span('logged-out', 'screen_view')['session.sampling_source'],
      'fallback',
    );
    // The SDK's stored value is cleared, so the next launch has no opinion.
    expect(File('${docs.path}/scout_user_sampling').existsSync(), isFalse);
  });

  test('standalone: the stored value decides the next launch', () async {
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'initNativeDelegate') return false;
      return null;
    });
    // A previous launch stored "no"; this launch's remote config cache is empty.
    await File('${docs.path}/scout_user_sampling').writeAsString('false');
    ScoutFlutter.initialize(config: config());
    await initialized();
    expect(ScoutFlutter.sessionSamplingDecision, (
      sampled: false,
      source: 'user',
    ));
    await activity('stored-no');
    await backend.awaitSpan('stored-no', 'error');
    await backend.awaitLog('stored-no');
    expect(backend.spans('stored-no', 'screen_view'), isEmpty);
  });

  test(
    'hybrid: forwards to the native owner and follows its decision',
    () async {
      final owner = _FakeNativeOwner();
      messenger.setMockMethodCallHandler(native, owner.handle);
      backend.publish({'alice': false});
      final rc = _AppRemoteConfig(backend.baseUrl, File('${docs.path}/app_rc'));

      ScoutFlutter.initialize(config: config(userSampling: rc.cachedValue()));
      await initialized();
      expect(ScoutFlutter.sessionId, owner.sessionId);
      expect(owner.initUserSampling, isNull);

      ScoutFlutter.setUser(
        id: 'anon-first',
      ); // anonymous → first id: no rotation
      await pumpChannel();
      ScoutFlutter.setUserSampling(await rc.fetch('alice'));
      ScoutFlutter.setUser(
        id: 'alice',
      ); // a switch while a value is pending → owner rotates
      await pumpChannel();
      expect(owner.stored, isFalse);
      expect(owner.rotations, 1);
      expect(
        ScoutFlutter.sessionId,
        owner.sessionId,
        reason: 'Dart re-reads the owner session',
      );
      expect(ScoutFlutter.sessionSamplingDecision, (
        sampled: false,
        source: 'user',
      ));

      ScoutFlutter.clearUser();
      await pumpChannel();
      expect(owner.stored, isNull);
      expect(owner.rotations, 2);
      expect(ScoutFlutter.sessionSamplingDecision, (
        sampled: true,
        source: 'fallback',
      ));
    },
  );

  test(
    'hybrid: a user restored right after initialize reaches the owner',
    () async {
      // Relaunch of a signed-in "no" user: the owner resumes her
      // user-decided session, and the app restores the user at startup,
      // before the delegation bootstrap has settled.
      final owner =
          _FakeNativeOwner()
            ..sampled = false
            ..source = 'user'
            ..stored = false;
      messenger.setMockMethodCallHandler(native, owner.handle);
      ScoutFlutter.initialize(config: config(userSampling: false));
      ScoutFlutter.setUser(id: 'alice');
      await initialized();
      expect(owner.userId, 'alice');
      expect(owner.rotations, 0, reason: 'restoring the user is no switch');

      ScoutFlutter.clearUser();
      await pumpChannel();
      expect(owner.rotations, 1, reason: 'logout leaves the "no" session');
      expect(ScoutFlutter.sessionSamplingDecision, (
        sampled: true,
        source: 'fallback',
      ));
    },
  );

  test('hybrid: a non-null init value reaches the owner both ways', () async {
    final owner = _FakeNativeOwner();
    messenger.setMockMethodCallHandler(native, owner.handle);
    ScoutFlutter.initialize(config: config(userSampling: false));
    await initialized();
    expect(
      owner.initUserSampling,
      isFalse,
      reason: 'passed into the native config',
    );
    expect(
      owner.stored,
      isFalse,
      reason: 'also forwarded for a host-owned session',
    );
  });
}

/// Waits for the asynchronous bootstrap to finish (tracer and exporters up).
Future<void> initialized() async {
  final sw = Stopwatch()..start();
  while (!ScoutFlutter.isInitialized &&
      sw.elapsed < const Duration(seconds: 15)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(
    ScoutFlutter.isInitialized,
    isTrue,
    reason: 'bootstrap did not finish',
  );
  await ScoutFlutter.refreshSessionIdentity();
}

/// Lets queued method-channel round trips settle.
Future<void> pumpChannel() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// A native owner with the same rules as scout-core: decide at session
/// start, persist the value, and rotate on a user switch while in play.
class _FakeNativeOwner {
  String sessionId = 'native-1';
  bool sampled = true;
  String source = 'fallback';
  bool? stored;
  bool? initUserSampling;
  String? userId;
  int rotations = 0;

  void _rotate() {
    rotations++;
    sessionId = 'native-${rotations + 1}';
    sampled = stored ?? true;
    source = stored == null ? 'fallback' : 'user';
  }

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'initNativeDelegate':
        initUserSampling = args['userSampling'] as bool?;
        if (initUserSampling != null) stored = initUserSampling;
        return true;
      case 'getSessionIdentity':
        return {
          'sessionId': sessionId,
          'anonymousId': 'anon',
          'sampled': sampled,
          'samplingSource': source,
        };
      case 'setUserSampling':
        stored = args['value'] as bool?;
        return null;
      case 'setUser':
        final prev = userId;
        userId = args['id'] as String?;
        if (prev != null &&
            userId != prev &&
            (source == 'user' || stored != null)) {
          _rotate();
        }
        return null;
      case 'clearUser':
        final prev = userId;
        userId = null;
        stored = null;
        // Rotates only while in play; the value was just cleared, so only
        // a user-decided current session counts.
        if (prev != null && source == 'user') _rotate();
        return null;
      default:
        return null;
    }
  }
}

/// App-side remote-config client, modelled on Firebase Remote Config.
class _AppRemoteConfig {
  _AppRemoteConfig(this.baseUrl, this.cache);
  final String baseUrl;
  final File cache;

  bool? cachedValue() {
    if (!cache.existsSync()) return null;
    final raw = cache.readAsStringSync();
    return raw == 'true' ? true : (raw == 'false' ? false : null);
  }

  Future<bool?> fetch(String user) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse(
          '$baseUrl/remote-config?user=${Uri.encodeQueryComponent(user)}',
        ),
      );
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      final v = (body['values'] as Map)['scout_user_sampling'] as bool?;
      if (v == null) {
        if (cache.existsSync()) cache.deleteSync();
      } else {
        cache.writeAsStringSync('$v');
      }
      return v;
    } finally {
      client.close();
    }
  }

  void clear() {
    if (cache.existsSync()) cache.deleteSync();
  }
}

/// Remote-config server with per-user targeting, plus an OTLP/JSON sink.
class _Backend {
  _Backend._(this._server);
  final HttpServer _server;
  Map<String, bool> _rules = {};
  int _version = 0;
  final _spans = <Map<String, String>>[];
  final _logs = <Map<String, String>>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_Backend> start() async {
    final b = _Backend._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    b._server.listen(b._handle);
    return b;
  }

  void publish(Map<String, bool> rules) {
    _rules = rules;
    _version++;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/remote-config') {
      final v = _rules[req.uri.queryParameters['user']];
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'version': _version,
          'values': {if (v != null) 'scout_user_sampling': v},
        }),
      );
      await req.response.close();
      return;
    }
    final bytes = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    try {
      // The SDK exports OTLP/protobuf.
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

  List<Map<String, String>> spans(String marker, String name) =>
      _spans.where((s) => s['marker'] == marker && s['@name'] == name).toList();
  Map<String, String> span(String marker, String name) =>
      spans(marker, name).single;
  Map<String, String> log(String marker) =>
      _logs.singleWhere((l) => l['marker'] == marker);

  Future<void> awaitSpan(String marker, String name) =>
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
