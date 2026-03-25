import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';
import 'package:scout_flutter/src/breadcrumb_manager.dart';

void main() {
  group('ScoutFlutter', () {
    test('config is null before initialization', () {
      expect(ScoutFlutter.config, isNull);
      expect(ScoutFlutter.isInitialized, false);
    });

    test('breadcrumbManager is accessible', () {
      expect(ScoutFlutter.breadcrumbManager, isA<BreadcrumbManager>());
    });

    test('addBreadcrumb records to breadcrumb manager', () {
      ScoutFlutter.addBreadcrumb('ui', 'test action');
      final crumbs = ScoutFlutter.breadcrumbManager.breadcrumbs;
      expect(crumbs.last['type'], 'ui');
      expect(crumbs.last['message'], 'test action');
    });
  });
}
