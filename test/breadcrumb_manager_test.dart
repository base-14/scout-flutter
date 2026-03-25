import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/breadcrumb_manager.dart';

void main() {
  group('BreadcrumbManager', () {
    late BreadcrumbManager manager;

    setUp(() {
      manager = BreadcrumbManager();
    });

    test('records breadcrumbs', () {
      manager.record('ui', 'tapped button');
      final crumbs = manager.breadcrumbs;
      expect(crumbs, hasLength(1));
      expect(crumbs.first['type'], 'ui');
      expect(crumbs.first['message'], 'tapped button');
      expect(crumbs.first['time'], isNotNull);
    });

    test('keeps only last 20 breadcrumbs', () {
      for (var i = 0; i < 25; i++) {
        manager.record('ui', 'action_$i');
      }
      final crumbs = manager.breadcrumbs;
      expect(crumbs, hasLength(20));
      expect(crumbs.first['message'], 'action_5');
      expect(crumbs.last['message'], 'action_24');
    });

    test('toJsonString returns valid JSON', () {
      manager.record('ui', 'tap');
      final json = manager.toJsonString();
      expect(json, contains('"type":"ui"'));
      expect(json, contains('"message":"tap"'));
    });

    test('clear removes all breadcrumbs', () {
      manager.record('ui', 'tap');
      manager.clear();
      expect(manager.breadcrumbs, isEmpty);
    });
  });
}
