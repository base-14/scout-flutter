import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

void main() {
  group('print capture filter', () {
    test('does not re-ingest the SDK\'s own [scout] diagnostics', () {
      // debugLogging prints '[scout] ...' lines via debugPrint; if the
      // capturePrintStatements hook ingests them, every captured line
      // produces another '[scout] log [info]' line — an infinite loop.
      expect(ScoutFlutter.shouldCapturePrint('[scout] init ok (...)'), isFalse);
      expect(
        ScoutFlutter.shouldCapturePrint('[scout] log [info] hello'),
        isFalse,
      );
      expect(
        ScoutFlutter.shouldCapturePrint('[scout] span long_task → drop'),
        isFalse,
      );
    });

    test('captures ordinary app prints', () {
      expect(ScoutFlutter.shouldCapturePrint('user tapped checkout'), isTrue);
      expect(ScoutFlutter.shouldCapturePrint('scout is great'), isTrue);
    });
  });
}
