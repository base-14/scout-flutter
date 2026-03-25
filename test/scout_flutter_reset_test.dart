import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScoutFlutter.resetForTesting', () {
    test('clears all state', () {
      // Set some state
      ScoutFlutter.setUser(id: 'user-1', email: 'test@example.com');
      expect(ScoutFlutter.userId, 'user-1');
      expect(ScoutFlutter.userEmail, 'test@example.com');

      ScoutFlutter.resetForTesting();

      expect(ScoutFlutter.isInitialized, false);
      expect(ScoutFlutter.config, isNull);
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userEmail, isNull);
    });

    test('can be called multiple times safely', () {
      ScoutFlutter.resetForTesting();
      ScoutFlutter.resetForTesting();

      expect(ScoutFlutter.isInitialized, false);
    });

    test('setUser and clearUser work correctly', () {
      ScoutFlutter.setUser(id: 'u1', email: 'a@b.com');
      expect(ScoutFlutter.userId, 'u1');
      expect(ScoutFlutter.userEmail, 'a@b.com');

      ScoutFlutter.clearUser();
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userEmail, isNull);

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
