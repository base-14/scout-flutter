import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/session_manager.dart';

void main() {
  group('SessionManager', () {
    test('generates a valid UUID v4 session ID', () {
      final manager = SessionManager(sampleRate: 100.0);
      final id = manager.sessionId;
      // UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      // where y is 8, 9, a, or b
      final uuidV4Regex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(id, matches(uuidV4Regex));
    });

    test('returns same session ID on repeated access', () {
      final manager = SessionManager(sampleRate: 100.0);
      final id1 = manager.sessionId;
      final id2 = manager.sessionId;
      expect(id1, equals(id2));
    });

    test('isSampled is true when sampleRate is 100', () {
      final manager = SessionManager(sampleRate: 100.0);
      expect(manager.isSampled, isTrue);
    });

    test('isSampled is false when sampleRate is 0', () {
      final manager = SessionManager(sampleRate: 0.0);
      expect(manager.isSampled, isFalse);
    });

    test('onBackground + onForeground within timeout keeps same session', () {
      final manager = SessionManager(sampleRate: 100.0, timeoutMinutes: 30);
      final originalId = manager.sessionId;

      manager.onBackground();
      // Simulate returning to foreground immediately (well within timeout)
      manager.onForeground();

      expect(manager.sessionId, equals(originalId));
    });

    test('rotateSession creates new session ID', () {
      final manager = SessionManager(sampleRate: 100.0);
      final originalId = manager.sessionId;

      manager.rotateSession();

      expect(manager.sessionId, isNot(equals(originalId)));
    });

    test('rotates session after inactivity timeout', () {
      var now = DateTime(2026, 1, 1, 12, 0);
      final m = SessionManager(
        sampleRate: 100.0,
        timeoutMinutes: 30,
        clock: () => now,
      );
      final id1 = m.sessionId;
      m.onBackground();
      // Advance clock past timeout
      now = DateTime(2026, 1, 1, 12, 31);
      m.onForeground();
      expect(m.sessionId, isNot(equals(id1)));
    });

    test('rotateSession re-rolls sampling decision', () {
      // Use a sample rate that deterministically tests re-rolling.
      // With rate 0, sampling is always false. After rotation it should
      // still be false (deterministic edge). We also verify with rate 100.
      final alwaysSampled = SessionManager(sampleRate: 100.0);
      alwaysSampled.rotateSession();
      expect(alwaysSampled.isSampled, isTrue);

      final neverSampled = SessionManager(sampleRate: 0.0);
      neverSampled.rotateSession();
      expect(neverSampled.isSampled, isFalse);

      // For a non-deterministic rate, verify that sampling is re-rolled
      // by running multiple rotations and checking the decision is a bool
      // (the actual value may vary, but the mechanism is exercised).
      final midRate = SessionManager(sampleRate: 50.0);
      final decisions = <bool>{};
      for (var i = 0; i < 100; i++) {
        midRate.rotateSession();
        decisions.add(midRate.isSampled);
      }
      // With 50% rate over 100 rotations, we should see both true and false.
      expect(decisions, contains(true));
      expect(decisions, contains(false));
    });
  });
}
