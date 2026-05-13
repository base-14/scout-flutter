import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scope.dart';

/// Walks every .dart file under lib/ (except `scope.dart` itself, which owns
/// the constant) and asserts that every InstrumentationScope name and every
/// scope-bearing OTel API call passes `kScopeName`.
///
/// This is the hard limit: any new code that mints its own scope name will
/// fail this test and CI.
void main() {
  group('SCOPE contract — every span/metric/log must use the SDK scope', () {
    test('exposes the canonical scope name', () {
      expect(kScopeName, 'base14.scout.flutter');
      expect(kScopeVersion, matches(r'^\d+\.\d+\.\d+$'));
    });

    test('forbids any other InstrumentationScope name anywhere in lib/', () {
      final libRoot = Directory('lib');
      final dartFiles = libRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('scope.dart'))
          .toList();

      final violations = <String>[];

      // 1) `tracerName: ...` and `tracerVersion: ...` named args on
      //    FlutterOTel.initialize must reference the kScope* constants.
      // 2) `FlutterOTel.meter(name: ...)` and `getMeter(name: ...)` must
      //    reference kScopeName.
      // 3) Direct `scope.name = ...` / `scope.version = ...` assignments
      //    on protobuf InstrumentationScope must reference kScope*.
      final tracerNameRe = RegExp(r'tracerName\s*:\s*([^,)\n]+)');
      final tracerVersionRe = RegExp(r'tracerVersion\s*:\s*([^,)\n]+)');
      final meterNameRe = RegExp(r'\bgetMeter\s*\(\s*name\s*:\s*([^,)\n]+)');
      final flutterMeterRe =
          RegExp(r'FlutterOTel\.meter\s*\(\s*name\s*:\s*([^,)\n]+)');
      final scopeNameAssignRe = RegExp(r'\bscope\.name\s*=\s*([^;\n]+);');
      final scopeVersionAssignRe = RegExp(r'\bscope\.version\s*=\s*([^;\n]+);');

      String stripCommentsAndStrings(String line) {
        return line.replaceAll(RegExp(r'//.*$'), '');
      }

      void check(
        RegExp re,
        String label,
        String expected,
        String path,
        int lineNo,
        String line,
      ) {
        final m = re.firstMatch(stripCommentsAndStrings(line));
        if (m == null) return;
        final actual = m.group(1)!.trim();
        if (actual != expected) {
          violations.add('  $path:$lineNo  $label uses `$actual` '
              '(must be `$expected`)');
        }
      }

      for (final file in dartFiles) {
        final lines = file.readAsLinesSync();
        final rel = file.path;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          check(tracerNameRe, 'tracerName', 'kScopeName', rel, i + 1, line);
          check(tracerVersionRe, 'tracerVersion', 'kScopeVersion', rel, i + 1,
              line);
          check(meterNameRe, 'getMeter(name:', 'kScopeName', rel, i + 1, line);
          check(flutterMeterRe, 'FlutterOTel.meter(name:', 'kScopeName', rel,
              i + 1, line);
          check(scopeNameAssignRe, 'scope.name =', 'kScopeName', rel, i + 1,
              line);
          check(scopeVersionAssignRe, 'scope.version =', 'kScopeVersion', rel,
              i + 1, line);
        }
      }

      if (violations.isNotEmpty) {
        fail(
          'Every span/metric/log MUST be emitted under the kScopeName '
          'constant (from lib/src/scope.dart). Found '
          '${violations.length} violation(s):\n${violations.join('\n')}',
        );
      }
    });
  });
}
