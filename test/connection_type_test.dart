import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  group('normalizeConnectionType', () {
    test('maps connectivity_plus "mobile" onto the spec value "cellular"', () {
      expect(ScoutFlutter.normalizeConnectionType('mobile'), 'cellular');
    });

    test('passes through values that already match the spec', () {
      for (final value in const ['wifi', 'ethernet', 'none']) {
        expect(ScoutFlutter.normalizeConnectionType(value), value);
      }
    });

    test('leaves transports outside the spec vocabulary untouched', () {
      expect(ScoutFlutter.normalizeConnectionType('vpn'), 'vpn');
      expect(ScoutFlutter.normalizeConnectionType('bluetooth'), 'bluetooth');
      expect(ScoutFlutter.normalizeConnectionType('other'), 'other');
    });
  });
}
