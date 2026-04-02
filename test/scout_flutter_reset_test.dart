import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScoutFlutter.resetForTesting', () {
    test('clears all state', () {
      // Set some state
      ScoutFlutter.setUser(id: 'user-1', attributes: {'enduser.email': 'test@example.com'});
      expect(ScoutFlutter.userId, 'user-1');
      expect(ScoutFlutter.userAttributes['enduser.email'], 'test@example.com');

      ScoutFlutter.resetForTesting();

      expect(ScoutFlutter.isInitialized, false);
      expect(ScoutFlutter.config, isNull);
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userAttributes, isEmpty);
    });

    test('can be called multiple times safely', () {
      ScoutFlutter.resetForTesting();
      ScoutFlutter.resetForTesting();

      expect(ScoutFlutter.isInitialized, false);
    });

    test('setUser and clearUser work correctly', () {
      ScoutFlutter.setUser(id: 'u1', attributes: {'enduser.email': 'a@b.com'});
      expect(ScoutFlutter.userId, 'u1');
      expect(ScoutFlutter.userAttributes['enduser.email'], 'a@b.com');

      ScoutFlutter.clearUser();
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userAttributes, isEmpty);

      ScoutFlutter.resetForTesting();
    });

    test('breadcrumb manager clears on reset', () {
      ScoutFlutter.addBreadcrumb('test', 'message');
      ScoutFlutter.resetForTesting();

      // After reset, breadcrumb manager should be empty
      // (toJsonString should return empty array)
      expect(ScoutFlutter.breadcrumbManager.toJsonString(), '[]');
    });
  });
}
