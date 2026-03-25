import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/auto_name_navigator_observer.dart';

class _TestPageA extends StatelessWidget {
  const _TestPageA();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Page A'));
}

class _TestPageB extends StatelessWidget {
  const _TestPageB();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Page B'));
}

void main() {
  group('AutoNameNavigatorObserver', () {
    testWidgets('extracts name from RouteSettings when provided', (
      tester,
    ) async {
      final pushes = <String>[];
      final observer = AutoNameNavigatorObserver(
        onScreenChanged: (name) => pushes.add(name),
      );

      await tester.pumpWidget(
        MaterialApp(navigatorObservers: [observer], home: const _TestPageA()),
      );

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/page_b'),
          builder: (_) => const _TestPageB(),
        ),
      );
      await tester.pumpAndSettle();

      expect(pushes, contains('/page_b'));
    });

    testWidgets('extracts widget class name when no RouteSettings name', (
      tester,
    ) async {
      final pushes = <String>[];
      final observer = AutoNameNavigatorObserver(
        onScreenChanged: (name) => pushes.add(name),
      );

      await tester.pumpWidget(
        MaterialApp(navigatorObservers: [observer], home: const _TestPageA()),
      );

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(MaterialPageRoute(builder: (_) => const _TestPageB()));
      await tester.pumpAndSettle();

      // Should have auto-detected the widget class name.
      expect(pushes.any((name) => name.contains('_TestPageB')), isTrue);
    });

    testWidgets('reports screen load time on push with RouteSettings name', (
      tester,
    ) async {
      final loadTimes = <MapEntry<String, Duration>>[];
      final observer = AutoNameNavigatorObserver(
        onScreenLoadTime: (name, duration) {
          loadTimes.add(MapEntry(name, duration));
        },
      );

      await tester.pumpWidget(
        MaterialApp(navigatorObservers: [observer], home: const _TestPageA()),
      );

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/page_b'),
          builder: (_) => const _TestPageB(),
        ),
      );
      await tester.pumpAndSettle();

      expect(loadTimes, isNotEmpty);
      expect(loadTimes.last.key, '/page_b');
      expect(loadTimes.last.value.inMicroseconds, greaterThan(0));
    });

    testWidgets('reports screen load time on push without RouteSettings name', (
      tester,
    ) async {
      final loadTimes = <MapEntry<String, Duration>>[];
      final observer = AutoNameNavigatorObserver(
        onScreenLoadTime: (name, duration) {
          loadTimes.add(MapEntry(name, duration));
        },
      );

      await tester.pumpWidget(
        MaterialApp(navigatorObservers: [observer], home: const _TestPageA()),
      );

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(MaterialPageRoute(builder: (_) => const _TestPageB()));
      await tester.pumpAndSettle();

      expect(loadTimes, isNotEmpty);
      expect(
        loadTimes.any((entry) => entry.key.contains('_TestPageB')),
        isTrue,
      );
      expect(loadTimes.last.value.inMicroseconds, greaterThan(0));
    });
  });
}
