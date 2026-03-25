import 'package:scout_flutter/scout_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScoutFlutterConfig', () {
    test('creates with required fields only', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
      );

      expect(config.serviceName, 'test-app');
      expect(config.endpoint, 'https://otel.example.com');
      expect(config.serviceVersion, '1.0.0');
      expect(config.enableAutoTapTracking, true);
      expect(config.enableErrorTracking, true);
      expect(config.enableLifecycleTracking, true);
      expect(config.customGestureDetector, isNull);
    });

    test('creates with all optional fields', () {
      final config = ScoutFlutterConfig(
        serviceName: 'test-app',
        endpoint: 'https://otel.example.com',
        serviceVersion: '2.0.0',
        environment: 'staging',
        resourceAttributes: {'team': 'mobile'},
        enableAutoTapTracking: false,
        enableErrorTracking: false,
        enableLifecycleTracking: false,
      );

      expect(config.serviceVersion, '2.0.0');
      expect(config.environment, 'staging');
      expect(config.resourceAttributes, {'team': 'mobile'});
      expect(config.enableAutoTapTracking, false);
    });
  });
}
