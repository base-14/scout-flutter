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
      expect(isFirstPartyHost('api.example.com', ['api.example.com']), isTrue);
    });

    test('isFirstPartyHost matches wildcard', () {
      expect(isFirstPartyHost('api.example.com', ['*.example.com']), isTrue);
    });

    test('isFirstPartyHost returns false for non-matching host', () {
      expect(isFirstPartyHost('api.other.com', ['*.example.com']), isFalse);
    });

    test('isFirstPartyHost returns false for null list', () {
      expect(isFirstPartyHost('api.example.com', null), isFalse);
    });
  });

  group('traceparent generation', () {
    test('generates valid W3C traceparent format', () {
      final tp = generateTraceparent('abc123', 'def456');
      expect(tp, '00-abc123-def456-01');
    });
  });
}
