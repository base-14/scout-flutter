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
      expect(config.sessionSampleRate, 1.0);
      expect(config.alwaysCaptureErrors, isTrue);
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
      final high = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost:4318',
        sessionSampleRate: 150.0,
      );
      expect(high.sessionSampleRate, 100.0);

      final low = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost:4318',
        sessionSampleRate: -10.0,
      );
      expect(low.sessionSampleRate, 0.0);
    });
  });
}
