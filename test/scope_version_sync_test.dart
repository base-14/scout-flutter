import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scope.dart';

void main() {
  test('kScopeVersion matches the pubspec package version', () {
    // The InstrumentationScope version on every span/metric/log is how a
    // backend tells which SDK version an app is running. It drifted once
    // (stuck at 0.1.5 while the package reached 0.1.22) — this guard
    // fails the build if scope.dart is not bumped alongside pubspec.yaml.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);

    expect(version, isNotNull, reason: 'pubspec.yaml must declare a version');
    expect(
      kScopeVersion,
      version,
      reason:
          'kScopeVersion (lib/src/scope.dart) must be bumped to match '
          'pubspec.yaml on every release',
    );
  });
}
