import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScoutFlutter.resetForTesting', () {
    test('clears all state', () {
      // Set some state
      ScoutFlutter.setUser(
        id: 'user-1',
        attributes: {'user.email': 'test@example.com'},
      );
      expect(ScoutFlutter.userId, 'user-1');
      expect(ScoutFlutter.userAttributes['user.email'], 'test@example.com');

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
      ScoutFlutter.setUser(id: 'u1', attributes: {'user.email': 'a@b.com'});
      expect(ScoutFlutter.userId, 'u1');
      expect(ScoutFlutter.userAttributes['user.email'], 'a@b.com');

      ScoutFlutter.clearUser();
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userAttributes, isEmpty);

      ScoutFlutter.resetForTesting();
    });

    test('setUser auto-prefixes bare attribute keys with user.', () {
      ScoutFlutter.setUser(
        id: 'u-1',
        attributes: {'email': 'a@b.c', 'phone': '+1234', 'name': 'Alice'},
      );
      expect(ScoutFlutter.userId, 'u-1');
      expect(ScoutFlutter.userAttributes['user.email'], 'a@b.c');
      expect(ScoutFlutter.userAttributes['user.phone'], '+1234');
      expect(ScoutFlutter.userAttributes['user.name'], 'Alice');
      expect(ScoutFlutter.userAttributes.containsKey('email'), isFalse);

      ScoutFlutter.resetForTesting();
    });

    test('setUser preserves already-prefixed user.* keys', () {
      ScoutFlutter.setUser(id: 'u-1', attributes: {'user.role': 'admin'});
      expect(ScoutFlutter.userAttributes['user.role'], 'admin');
      expect(
        ScoutFlutter.userAttributes.containsKey('user.user.role'),
        isFalse,
      );

      ScoutFlutter.resetForTesting();
    });

    test('setUser without id emits attributes only', () {
      ScoutFlutter.setUser(attributes: {'tenant': 'acme'});
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userAttributes['user.tenant'], 'acme');

      ScoutFlutter.resetForTesting();
    });

    test('setUser with empty id is treated as no id', () {
      ScoutFlutter.setUser(id: '', attributes: {'plan': 'pro'});
      expect(ScoutFlutter.userId, isNull);
      expect(ScoutFlutter.userAttributes['user.plan'], 'pro');

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
