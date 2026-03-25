import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  group('ScoutFlutterConfig Phase 2 fields', () {
    test('enablePerformanceMetrics defaults to true', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost',
      );
      expect(config.enablePerformanceMetrics, true);
    });

    test('enableStartupTracking defaults to true', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost',
      );
      expect(config.enableStartupTracking, true);
    });

    test('enableConnectivityTracking defaults to true', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost',
      );
      expect(config.enableConnectivityTracking, true);
    });

    test('Phase 2 fields can be disabled', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test',
        endpoint: 'http://localhost',
        enablePerformanceMetrics: false,
        enableStartupTracking: false,
        enableConnectivityTracking: false,
      );
      expect(config.enablePerformanceMetrics, false);
      expect(config.enableStartupTracking, false);
      expect(config.enableConnectivityTracking, false);
    });
  });
}
