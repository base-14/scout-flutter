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
  group('View session tracking', () {
    testWidgets('onScreenEnter fires on push', (tester) async {
      final enters = <String>[];
      final observer = AutoNameNavigatorObserver(
        onScreenEnter: (name) => enters.add(name),
      );

      await tester.pumpWidget(
        MaterialApp(navigatorObservers: [observer], home: const _TestPageA()),
      );
      await tester.pumpAndSettle();

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/page_b'),
          builder: (_) => const _TestPageB(),
        ),
      );
      await tester.pumpAndSettle();

      expect(enters, contains('/page_b'));
    });

    testWidgets('onScreenExit fires with time spent on second push', (
      tester,
    ) async {
      final exits = <MapEntry<String, Duration>>[];
      final observer = AutoNameNavigatorObserver(
        onScreenExit: (name, timeSpent) {
          exits.add(MapEntry(name, timeSpent));
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          initialRoute: '/',
          routes: {'/': (_) => const _TestPageA()},
        ),
      );
      await tester.pumpAndSettle();

      // Wait a bit so there is measurable time spent on the first screen.
      await tester.pump(const Duration(milliseconds: 50));

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/page_b'),
          builder: (_) => const _TestPageB(),
        ),
      );
      await tester.pumpAndSettle();

      // The exit for '/' should have fired when we pushed '/page_b'.
      expect(exits, isNotEmpty);
      expect(exits.last.key, '/');
      // The stopwatch measures real elapsed time; with tester.pump(50ms)
      // and pumpAndSettle, actual wall-clock time should exceed 0.
      expect(exits.last.value.inMicroseconds, greaterThan(0));
    });

    testWidgets('onScreenExit fires on pop', (tester) async {
      final exits = <MapEntry<String, Duration>>[];
      final observer = AutoNameNavigatorObserver(
        onScreenExit: (name, timeSpent) {
          exits.add(MapEntry(name, timeSpent));
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          initialRoute: '/',
          routes: {'/': (_) => const _TestPageA()},
        ),
      );
      await tester.pumpAndSettle();

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/page_b'),
          builder: (_) => const _TestPageB(),
        ),
      );
      await tester.pumpAndSettle();

      // Clear exits from the push so we only see the pop exit.
      exits.clear();

      navState.pop();
      await tester.pumpAndSettle();

      // onScreenExit should have fired for '/page_b' when it was popped.
      expect(exits, isNotEmpty);
      expect(exits.any((e) => e.key == '/page_b'), isTrue);
    });

    testWidgets('onScreenEnter fires for previous route on pop', (
      tester,
    ) async {
      final enters = <String>[];
      final observer = AutoNameNavigatorObserver(
        onScreenEnter: (name) => enters.add(name),
      );

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          initialRoute: '/',
          routes: {'/': (_) => const _TestPageA()},
        ),
      );
      await tester.pumpAndSettle();

      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/page_b'),
          builder: (_) => const _TestPageB(),
        ),
      );
      await tester.pumpAndSettle();

      // Clear enters so we only capture the pop-triggered enter.
      enters.clear();

      navState.pop();
      await tester.pumpAndSettle();

      // onScreenEnter should fire for '/' when we pop back to it.
      expect(enters, contains('/'));
    });
  });
}
