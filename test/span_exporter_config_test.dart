import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  group('span exporter config', () {
    test('disables retries so ambiguous failures cannot duplicate spans', () {
      final config = ScoutFlutter.buildSpanExporterConfig(
        endpoint: 'https://otel.example.com',
        headers: {'Authorization': 'Bearer x'},
      );

      expect(config.maxRetries, 0);
      // Upstream config normalizes header keys to lowercase.
      expect(config.headers['authorization'], 'Bearer x');
    });
  });
}
