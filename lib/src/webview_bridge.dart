import 'dart:convert';

import 'scout_rum.dart';

/// Bridges an embedded WebView's RUM session to the native Scout
/// session so a single user-flow produces one unified session
/// instead of two disconnected ones.
///
/// **How it works**
/// 1. We register a JavaScript channel (`ScoutBridge` by default) the
///    page can `postMessage` into.
/// 2. We inject a small JS shim that polls for the page's web SDK
///    (`window.Scout`) and calls its `setWebViewBridge(...)` hook with
///    the native session_id + anonymous_id + a `send` function that
///    routes spans back through the channel.
/// 3. The web SDK stops POSTing to its own OTLP endpoint and instead
///    hands every span to `send` — which arrives here as a
///    `JavaScriptMessage`. We re-emit it as a proper OTel span under
///    the native session, with `span.source = "webview"` so backends
///    can tell where it came from.
///
/// **What the embedded page needs**
/// - Be instrumented with `@base14/scout-react` v0.2.0+ on the web
///   entry. That SDK version ships `Scout.setWebViewBridge(...)`.
/// - Have JavaScript enabled in the WebView (`JavaScriptMode
///   .unrestricted` for `webview_flutter`).
///
/// **Example with `webview_flutter`** (works the same way for
/// `flutter_inappwebview` — just adapt the controller calls):
/// ```dart
/// import 'package:webview_flutter/webview_flutter.dart';
/// import 'package:scout_flutter/scout_flutter.dart';
///
/// final controller = WebViewController()
///   ..setJavaScriptMode(JavaScriptMode.unrestricted);
///
/// await ScoutWebViewBridge.attach(
///   runJavaScript: controller.runJavaScript,
///   addJavaScriptChannel: (name, onMessage) {
///     controller.addJavaScriptChannel(
///       name,
///       onMessageReceived: (m) => onMessage(m.message),
///     );
///   },
/// );
///
/// await controller.loadRequest(Uri.parse('https://app.example.com'));
/// ```
///
/// The bridge is one-way (web → native). Native spans don't propagate
/// into the web SDK — they don't need to, since the web SDK no longer
/// has its own exporter once the bridge is wired.
class ScoutWebViewBridge {
  static const String _defaultChannelName = 'ScoutBridge';

  /// Register the bridge's JS channel. Call once per WebView, before
  /// the first page load. The channel name survives navigations, but
  /// the JS shim itself does NOT — call [injectShim] from your
  /// WebView's "page finished loading" callback so a fresh shim runs
  /// after every navigation.
  ///
  /// [addJavaScriptChannel] registers a channel the page can
  /// `postMessage` into. The callback receives the raw message string.
  /// [channelName] overrides the bridge channel name (default
  /// `ScoutBridge`). Match this on the web SDK side if you change it.
  static void attach({
    required void Function(
      String channelName,
      void Function(String message) onMessage,
    )
    addJavaScriptChannel,
    String channelName = _defaultChannelName,
  }) {
    addJavaScriptChannel(channelName, _handleBridgeMessage);
  }

  /// Inject the JS shim into the currently-loaded page. Call this from
  /// your WebView plugin's "page finished" / "onLoad" / "didFinish"
  /// callback — the shim only lives as long as the page does, so each
  /// navigation needs a fresh inject. Idempotent within a single page
  /// (the shim sets a sentinel).
  static Future<void> injectShim({
    required Future<void> Function(String js) runJavaScript,
    String channelName = _defaultChannelName,
  }) async {
    final sessionId = ScoutFlutter.sessionId ?? '';
    final anonymousId = ScoutFlutter.anonymousId ?? '';
    final shim = _buildShim(
      channelName: channelName,
      sessionId: sessionId,
      anonymousId: anonymousId,
    );
    try {
      await runJavaScript(shim);
    } catch (_) {
      // WebView may have navigated away during the call — ignore.
    }
  }

  /// Re-emit a bridged span from the web SDK under the native session.
  ///
  /// Expected payload shape (JSON string):
  /// ```json
  /// {
  ///   "type": "user_interaction",
  ///   "attributes": { "user_interaction.target": "Buy" },
  ///   "timestamp_ms": 1716000000000
  /// }
  /// ```
  /// Unknown fields are dropped. Bad JSON is silently ignored — the
  /// bridge must never throw across the channel boundary.
  static void _handleBridgeMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;

      final type = decoded['type'];
      if (type is! String || type.isEmpty) return;

      final rawAttrs = decoded['attributes'];
      final attrs = <String, Object>{};
      if (rawAttrs is Map) {
        rawAttrs.forEach((k, v) {
          if (k is String && v != null) {
            // OTel attributes accept String / num / bool / List
            // primitives. Anything more exotic gets JSON-stringified.
            if (v is String || v is num || v is bool) {
              attrs[k] = v as Object;
            } else {
              attrs[k] = jsonEncode(v);
            }
          }
        });
      }
      attrs['span.source'] = 'webview';

      ScoutFlutter.emitBridgedSpan(type, attrs);
    } catch (_) {
      // Discard malformed payloads — never propagate back.
    }
  }

  /// JS shim injected into the WebView. Polls for the page's web SDK
  /// (`window.Scout`) every 100 ms up to 50 attempts (~5 s), then
  /// gives up quietly. Idempotent — checks a sentinel so reloads or
  /// repeat `attach()` calls don't double-bridge.
  static String _buildShim({
    required String channelName,
    required String sessionId,
    required String anonymousId,
  }) {
    // jsonEncode handles quoting / escaping safely.
    final encSession = jsonEncode(sessionId);
    final encAnon = jsonEncode(anonymousId);
    final encChannel = jsonEncode(channelName);
    return '''
(function() {
  if (window.__SCOUT_WEBVIEW_BRIDGED) return;
  window.__SCOUT_WEBVIEW_BRIDGED = true;
  var nativeSessionId = $encSession;
  var nativeAnonymousId = $encAnon;
  var channelName = $encChannel;
  function send(payload) {
    try {
      var ch = window[channelName];
      if (ch && typeof ch.postMessage === 'function') {
        ch.postMessage(typeof payload === 'string' ? payload : JSON.stringify(payload));
      }
    } catch (_) {}
  }
  function bind(attempt) {
    var S = window.Scout || window.scout;
    if (S && typeof S.setWebViewBridge === 'function') {
      try {
        S.setWebViewBridge({
          sessionId: nativeSessionId,
          anonymousId: nativeAnonymousId,
          send: send,
        });
      } catch (_) {}
      return;
    }
    if (attempt < 50) {
      setTimeout(function() { bind(attempt + 1); }, 100);
    }
  }
  bind(0);
})();
''';
  }
}
