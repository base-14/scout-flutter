import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/scout_flutter.dart';

/// Captures the JS the bridge would have run in a real WebView.
Future<String> captureShim({
  ScoutWebViewMode mode = ScoutWebViewMode.relay,
  String channelName = 'ScoutBridge',
}) async {
  late String js;
  await ScoutWebViewBridge.injectShim(
    runJavaScript: (source) async => js = source,
    mode: mode,
    channelName: channelName,
  );
  return js;
}

void main() {
  group('injectShim — shape', () {
    test('binds via setWebViewBridge and polls for the web SDK', () async {
      final js = await captureShim();
      expect(js, contains('S.setWebViewBridge(bridge)'));
      expect(js, contains('window.Scout || window.scout'));
      expect(js, contains('attempt < 50'));
    });

    test(
      'relay mode wires send() and asks the page to stop exporting',
      () async {
        final js = await captureShim(mode: ScoutWebViewMode.relay);
        expect(js, contains('var relay = true;'));
        expect(js, contains('bridge.relay = true;'));
        expect(js, contains('bridge.send = function(payload)'));
      },
    );

    test('sessionOnly mode passes identity only — no send, no relay', () async {
      final js = await captureShim(mode: ScoutWebViewMode.sessionOnly);
      expect(js, contains('var relay = false;'));
      expect(js, contains('sessionId: nativeSessionId'));
      expect(js, contains('anonymousId: nativeAnonymousId'));
      // The assignments are guarded by `if (relay)`, so they are present
      // in the source but never execute. What must hold is that the
      // bind gate does not wait on a transport that will never exist.
      expect(js, contains('(!relay || post)'));
    });

    test('defaults to relay so existing integrations keep working', () async {
      expect(await captureShim(), contains('var relay = true;'));
    });
  });

  group('injectShim — transport detection', () {
    test('supports webview_flutter postMessage channels', () async {
      final js = await captureShim();
      expect(js, contains("typeof ch.postMessage === 'function'"));
      expect(js, contains('ch.postMessage(msg)'));
    });

    test('supports flutter_inappwebview callHandler channels', () async {
      final js = await captureShim();
      expect(js, contains('window.flutter_inappwebview'));
      expect(js, contains('iaw.callHandler(channelName, msg)'));
    });

    test('threads a custom channel name through both transports', () async {
      final js = await captureShim(channelName: 'MyBridge');
      expect(js, contains('var channelName = "MyBridge";'));
    });
  });

  group('injectShim — re-injection', () {
    test('keys the sentinel on the session id, not a bare boolean', () async {
      final js = await captureShim();
      expect(
        js,
        contains('window.__SCOUT_WEBVIEW_BRIDGED === nativeSessionId'),
      );
      expect(js, contains('window.__SCOUT_WEBVIEW_BRIDGED = nativeSessionId;'));
      // A plain `if (flag) return` would pin the page to a stale session.
      expect(
        js,
        isNot(contains('if (window.__SCOUT_WEBVIEW_BRIDGED) return;')),
      );
    });

    test('marks the sentinel only after a successful bind', () async {
      final js = await captureShim();
      final bindAt = js.indexOf('S.setWebViewBridge(bridge)');
      final markAt = js.indexOf(
        'window.__SCOUT_WEBVIEW_BRIDGED = nativeSessionId;',
      );
      expect(bindAt, greaterThan(0));
      expect(markAt, greaterThan(bindAt));
    });
  });

  group('injectShim — resilience', () {
    test('swallows a WebView that navigated away mid-call', () async {
      await expectLater(
        ScoutWebViewBridge.injectShim(
          runJavaScript: (_) async => throw StateError('navigated'),
        ),
        completes,
      );
    });

    test('escapes identity values into the JS source', () async {
      final js = await captureShim();
      // Uninitialised SDK yields empty ids; they must still be quoted,
      // never interpolated bare into the script.
      expect(js, contains('var nativeSessionId = "";'));
      expect(js, contains('var nativeAnonymousId = "";'));
    });
  });

  group('attach — inbound messages', () {
    late void Function(String) onMessage;

    setUp(() {
      ScoutWebViewBridge.attach(
        addJavaScriptChannel: (_, handler) => onMessage = handler,
      );
    });

    test('registers under the default channel name', () {
      String? registered;
      ScoutWebViewBridge.attach(
        addJavaScriptChannel: (name, _) => registered = name,
      );
      expect(registered, 'ScoutBridge');
    });

    test('registers under a custom channel name', () {
      String? registered;
      ScoutWebViewBridge.attach(
        addJavaScriptChannel: (name, _) => registered = name,
        channelName: 'MyBridge',
      );
      expect(registered, 'MyBridge');
    });

    test('never throws on malformed payloads', () {
      for (final payload in <String>[
        '',
        'not json',
        '[]',
        'null',
        '{}',
        '{"type": ""}',
        '{"type": 42}',
        '{"type": "ok", "attributes": "not a map"}',
        '{"type": "ok", "attributes": {"k": null}}',
        '{"type": "ok", "timestamp_ms": "not a number"}',
      ]) {
        expect(() => onMessage(payload), returnsNormally, reason: payload);
      }
    });

    test('accepts a well-formed payload without an initialized SDK', () {
      expect(
        () => onMessage(
          '{"type":"user_interaction",'
          '"attributes":{"user_interaction.target":"Buy","n":1,"b":true},'
          '"timestamp_ms":1716000000000}',
        ),
        returnsNormally,
      );
    });
  });
}
