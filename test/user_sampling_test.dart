import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';
import 'package:scout_flutter/src/scout_platform_channel.dart';
import 'package:scout_flutter/src/scout_sample_gate.dart';
import 'package:scout_flutter/src/session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var now = DateTime.utc(2026, 11, 4, 10);
  DateTime clock() => now;
  bool? pending;

  SessionManager manager({double rate = 100, int maxDuration = 0}) =>
      SessionManager(
        sampleRate: rate,
        maxDurationMinutes: maxDuration,
        clock: clock,
        pendingUserSampling: () => pending,
      );

  setUp(() {
    now = DateTime.utc(2026, 11, 4, 10);
    pending = null;
  });

  group('§3 decision table', () {
    test('true keeps the session even at a 0% fallback rate', () {
      pending = true;
      final sm = manager(rate: 0);
      expect(sm.isSampled, isTrue);
      expect(sm.samplingSource, kSamplingSourceUser);
    });

    test('false drops spans even at a 100% fallback rate', () {
      pending = false;
      final sm = manager(rate: 100);
      expect(sm.isSampled, isFalse);
      expect(sm.samplingSource, kSamplingSourceUser);
    });

    test('null falls back to the rate', () {
      expect(manager(rate: 100).isSampled, isTrue);
      expect(manager(rate: 0).isSampled, isFalse);
      expect(manager().samplingSource, kSamplingSourceFallback);
    });

    test(
      'a user "no" still allows logs and metrics; a fallback "no" does not',
      () {
        pending = false;
        final userNo = manager();
        pending = null;
        final fallbackNo = manager(rate: 0);
        final userNoGate = ScoutSampleGate(
          sessionResolver: () => userNo,
          alwaysCaptureErrors: true,
        );
        final fallbackNoGate = ScoutSampleGate(
          sessionResolver: () => fallbackNo,
          alwaysCaptureErrors: true,
        );
        expect(userNoGate.shouldSampleSpan('screen_view'), isFalse);
        expect(userNoGate.shouldSampleSpan('error'), isTrue);
        expect(userNoGate.shouldSampleLog(isError: false), isTrue);
        expect(userNoGate.shouldSampleMetric(), isTrue);
        expect(fallbackNoGate.shouldSampleLog(isError: false), isFalse);
        expect(fallbackNoGate.shouldSampleMetric(), isFalse);
      },
    );

    test('alwaysCaptureErrors=false sends no error spans for a "no" user', () {
      pending = false;
      final sm = manager();
      final gate = ScoutSampleGate(
        sessionResolver: () => sm,
        alwaysCaptureErrors: false,
      );
      expect(gate.shouldSampleSpan('error'), isFalse);
      expect(gate.shouldSampleLog(isError: true), isTrue); // logs still flow
    });
  });

  group('never mid-session', () {
    test('a pending change applies only after rotation', () {
      final sm = manager();
      final first = sm.sessionId;
      pending = false;
      expect(sm.sessionId, first);
      expect(sm.isSampled, isTrue);
      sm.rotateSession();
      expect(sm.sessionId, isNot(first));
      expect(sm.isSampled, isFalse);
      expect(sm.samplingSource, kSamplingSourceUser);
    });

    test('max-duration rotation picks up the new value', () {
      final sm = manager(maxDuration: 60);
      final first = sm.sessionId;
      pending = false;
      now = now.add(const Duration(minutes: 61));
      expect(sm.sessionId, isNot(first));
      expect(sm.isSampled, isFalse);
    });

    test('idle rotation picks up the new value', () {
      final sm = manager();
      final first = sm.sessionId;
      sm.onBackground();
      pending = false;
      now = now.add(const Duration(minutes: 31));
      sm.onForeground();
      expect(sm.sessionId, isNot(first));
      expect(sm.isSampled, isFalse);
    });
  });

  group('persistence', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('scout_us'));
    tearDown(() async => dir.delete(recursive: true));

    test('a resumed session keeps its decision and source', () async {
      pending = false;
      final a = manager();
      await a.start(directory: dir);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final id = a.sessionId;
      pending = true; // the next launch passes a different value
      now = now.add(const Duration(minutes: 1));
      final b = manager();
      await b.start(directory: dir);
      expect(b.sessionId, id);
      expect(b.isSampled, isFalse);
      expect(b.samplingSource, kSamplingSourceUser);
    });

    test('a legacy record without a source reads as fallback', () async {
      final ms = now.millisecondsSinceEpoch;
      await File('${dir.path}/scout_session.json').writeAsString(
        jsonEncode({
          'v': 1,
          'id': 'legacy',
          'startedAt': ms,
          'lastActiveAt': ms,
          'sampled': true,
        }),
      );
      final sm = manager();
      await sm.start(directory: dir);
      expect(sm.sessionId, 'legacy');
      expect(sm.samplingSource, kSamplingSourceFallback);
    });
  });

  group('adopting a native owner', () {
    test('follows the owner decision and source', () {
      final sm = manager();
      sm.adoptExternalSampling(false, samplingSource: 'user');
      expect(sm.isSampled, isFalse);
      expect(sm.samplingSource, kSamplingSourceUser);
      expect(sm.allowsLogsAndMetrics, isTrue);
      sm.adoptExternalSampling(false); // legacy owner sends no source
      expect(sm.samplingSource, kSamplingSourceFallback);
      expect(sm.allowsLogsAndMetrics, isFalse);
    });
  });

  group('§5 user-switch rotation predicate', () {
    bool rotate(String? prev, String? next, String source, bool? p) =>
        shouldRotateOnIdentityChange(
          previousUserId: prev,
          newUserId: next,
          currentSource: source,
          pending: p,
        );
    test('matrix', () {
      expect(rotate(null, 'a', 'user', true), isFalse);
      expect(rotate('a', 'a', 'user', false), isFalse);
      expect(rotate('a', 'b', 'user', null), isTrue);
      expect(rotate('a', 'b', 'fallback', false), isTrue);
      expect(rotate('a', 'b', 'fallback', null), isFalse);
      expect(rotate('a', null, 'user', null), isTrue);
      expect(rotate('a', null, 'fallback', null), isFalse);
    });
  });

  group('platform channel', () {
    const channel = MethodChannel('com.base14.scout_flutter');
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getSessionIdentity') {
              return {
                'sessionId': 's',
                'anonymousId': 'a',
                'sampled': false,
                'samplingSource': 'user',
              };
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      ScoutFlutter.resetForTesting();
    });

    test(
      'forwards setUserSampling, setUser and clearUser with their args',
      () async {
        await ScoutPlatformChannel.setUserSampling(false);
        await ScoutPlatformChannel.setUserSampling(null);
        await ScoutPlatformChannel.setUser(
          id: 'alice',
          attributes: {'user.plan': 'pro'},
        );
        await ScoutPlatformChannel.clearUser();
        expect(calls.map((c) => c.method), [
          'setUserSampling',
          'setUserSampling',
          'setUser',
          'clearUser',
        ]);
        expect(calls[0].arguments, {'value': false});
        expect(calls[1].arguments, {'value': null});
        expect(calls[2].arguments, {
          'id': 'alice',
          'attributes': {'user.plan': 'pro'},
        });
      },
    );

    test('getSessionIdentity parses the sampling source', () async {
      final id = await ScoutPlatformChannel.getSessionIdentity();
      expect(id?.sampled, isFalse);
      expect(id?.samplingSource, 'user');
    });

    test('setUserSampling before initialize is held and reported', () {
      ScoutFlutter.setUserSampling(false);
      expect(ScoutFlutter.userSampling, isFalse);
      ScoutFlutter.clearUser();
      expect(ScoutFlutter.userSampling, isNull);
    });
  });
}
