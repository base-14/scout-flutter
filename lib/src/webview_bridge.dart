import 'dart:convert';

import 'scout_rum.dart';

/// How an embedded WebView's telemetry reaches the backend.
enum ScoutWebViewMode {
  /// The page adopts the native session + anonymous id and keeps
  /// exporting to the collector itself.
  ///
  /// One copy of every signal, and the page's logs, metrics and web
  /// vitals all survive — the relay carries spans only. Needs no
  /// [ScoutWebViewBridge.attach] call and no JS channel; the page must
  /// be able to reach the collector, which for a browser context means
  /// the collector must allow CORS from the page's origin.
  ///
  /// Prefer this unless the WebView genuinely cannot reach the
  /// collector.
  sessionOnly,

  /// The page stops POSTing spans and hands them to the native SDK,
  /// which re-emits them under the native session.
  ///
  /// Use when the WebView cannot reach the collector directly — a
  /// locked-down network, or a collector with no CORS allowance for the
  /// page's origin. Requires [ScoutWebViewBridge.attach].
  ///
  /// Only spans travel the bridge. The page's logs and metrics keep
  /// going out over HTTP, so they still need collector reachability;
  /// if the page truly has no network path, they are lost.
  ///
  /// Requires `@base14/scout-react` **0.1.16+** on the page. Older
  /// versions ignore the relay flag and *mirror* instead: the span is
  /// exported by the page **and** re-emitted natively, so it lands in
  /// the backend twice.
  relay,
}

/// Bridges an embedded WebView's RUM session to the native Scout
/// session so a single user-flow produces one unified session
/// instead of two disconnected ones.
///
/// **How it works**
/// 1. We inject a small JS shim that polls for the page's web SDK
///    (`window.Scout`) and calls its `setWebViewBridge(...)` hook with
///    the native session_id + anonymous_id.
/// 2. In [ScoutWebViewMode.relay] we also register a JavaScript channel
///    (`ScoutBridge` by default) and pass the page a `send` function
///    that routes spans back through it. Each arriving span is
///    re-emitted as a proper OTel span under the native session, with
///    `span.source = "webview"` so backends can tell where it came
///    from.
///
/// **What the embedded page needs**
/// - To be instrumented with `@base14/scout-react` **0.1.6+** on the web
///   entry (that is the first published version shipping
///   `Scout.setWebViewBridge(...)`). [ScoutWebViewMode.relay] wants
///   **0.1.16+** — see the enum for what older versions do instead.
/// - JavaScript enabled in the WebView.
///
/// **Example — `flutter_inappwebview`, session-only (recommended)**
/// ```dart
/// InAppWebView(
///   initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
///   onLoadStop: (controller, url) async {
///     await ScoutWebViewBridge.injectShim(
///       runJavaScript: (js) => controller.evaluateJavascript(source: js),
///     );
///   },
/// );
/// ```
///
/// **Example — `flutter_inappwebview`, relay**
/// ```dart
/// InAppWebView(
///   onWebViewCreated: (controller) {
///     ScoutWebViewBridge.attach(
///       addJavaScriptChannel: (name, onMessage) {
///         controller.addJavaScriptHandler(
///           handlerName: name,
///           callback: (args) {
///             if (args.isNotEmpty) onMessage(args.first.toString());
///           },
///         );
///       },
///     );
///   },
///   onLoadStop: (controller, url) async {
///     await ScoutWebViewBridge.injectShim(
///       runJavaScript: (js) => controller.evaluateJavascript(source: js),
///       mode: ScoutWebViewMode.relay,
///     );
///   },
/// );
/// ```
///
/// **Example — `webview_flutter`, relay**
/// ```dart
/// final controller = WebViewController()
///   ..setJavaScriptMode(JavaScriptMode.unrestricted);
///
/// ScoutWebViewBridge.attach(
///   addJavaScriptChannel: (name, onMessage) {
///     controller.addJavaScriptChannel(
///       name,
///       onMessageReceived: (m) => onMessage(m.message),
///     );
///   },
/// );
///
/// controller.setNavigationDelegate(
///   NavigationDelegate(
///     onPageFinished: (_) => ScoutWebViewBridge.injectShim(
///       runJavaScript: controller.runJavaScript,
///       mode: ScoutWebViewMode.relay,
///     ),
///   ),
/// );
/// ```
///
/// The bridge is one-way (web → native) and carries telemetry only.
/// Native spans do not propagate into the web SDK, and identity beyond
/// session_id / anonymous_id (user id, feature flags, the current
/// screen) is not synchronised — push those over your own channel.
class ScoutWebViewBridge {
  static const String _defaultChannelName = 'ScoutBridge';

  /// Register the bridge's JS channel. Required for
  /// [ScoutWebViewMode.relay] and unused by
  /// [ScoutWebViewMode.sessionOnly].
  ///
  /// Call once per WebView, before the first page load. The channel
  /// survives navigations, but the JS shim itself does NOT — call
  /// [injectShim] from your WebView's "page finished loading" callback
  /// so a fresh shim runs after every navigation.
  ///
  /// [addJavaScriptChannel] registers a channel the page can post into.
  /// The callback receives the raw message string. See the class docs
  /// for how this maps onto `webview_flutter` and
  /// `flutter_inappwebview`.
  /// [channelName] overrides the bridge channel name (default
  /// `ScoutBridge`); pass the same value to [injectShim].
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
  /// your WebView plugin's "page finished" / `onLoadStop` / "didFinish"
  /// callback — the shim only lives as long as the page does, so each
  /// navigation needs a fresh inject.
  ///
  /// Cheap to call repeatedly: the shim re-binds only when the native
  /// session id has changed since the last inject, so you can also call
  /// it on app resume to re-sync after a session rotation.
  ///
  /// [mode] selects who delivers the page's spans — see
  /// [ScoutWebViewMode]. Defaults to [ScoutWebViewMode.relay] for
  /// backwards compatibility; [ScoutWebViewMode.sessionOnly] is the
  /// better choice whenever the WebView can reach the collector.
  static Future<void> injectShim({
    required Future<void> Function(String js) runJavaScript,
    String channelName = _defaultChannelName,
    ScoutWebViewMode mode = ScoutWebViewMode.relay,
  }) async {
    final sessionId = ScoutFlutter.sessionId ?? '';
    final anonymousId = ScoutFlutter.anonymousId ?? '';
    final shim = _buildShim(
      channelName: channelName,
      sessionId: sessionId,
      anonymousId: anonymousId,
      mode: mode,
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

      // The span's own start/end are stamped when we re-emit, which is
      // when the message crossed the channel — the tracer gives us no
      // way to backdate a span. Carry the page's own clock reading as
      // an attribute so the real event time survives the hop; the gap
      // between the two is bridge latency, normally milliseconds but
      // seconds when a backgrounded WebView is throttled.
      final ts = decoded['timestamp_ms'];
      if (ts is num) {
        attrs['webview.timestamp_ms'] = ts;
      }

      ScoutFlutter.emitBridgedSpan(type, attrs);
    } catch (_) {
      // Discard malformed payloads — never propagate back.
    }
  }

  /// JS shim injected into the WebView. Polls for the page's web SDK
  /// (`window.Scout`) every 100 ms up to 50 attempts (~5 s), then gives
  /// up quietly.
  ///
  /// Re-injection is idempotent per native session: the sentinel stores
  /// the session id the page was bound to, so injecting again with the
  /// same session does nothing while a rotated session re-binds. A
  /// plain boolean sentinel would leave the page pinned to a stale
  /// session for the rest of its life.
  ///
  /// The `send` transport is detected at runtime rather than
  /// configured, because the two common Flutter WebView plugins expose
  /// channels differently: `webview_flutter` defines
  /// `window.<channel>.postMessage`, `flutter_inappwebview` routes
  /// through `window.flutter_inappwebview.callHandler(<channel>, ...)`.
  /// In relay mode we wait for a transport before binding, so the page
  /// never has its exporter switched off with nowhere to send.
  static String _buildShim({
    required String channelName,
    required String sessionId,
    required String anonymousId,
    required ScoutWebViewMode mode,
  }) {
    // jsonEncode handles quoting / escaping safely.
    final encSession = jsonEncode(sessionId);
    final encAnon = jsonEncode(anonymousId);
    final encChannel = jsonEncode(channelName);
    final relay = mode == ScoutWebViewMode.relay;
    return '''
(function() {
  var nativeSessionId = $encSession;
  var nativeAnonymousId = $encAnon;
  var channelName = $encChannel;
  var relay = $relay;
  if (window.__SCOUT_WEBVIEW_BRIDGED === nativeSessionId) return;
  function transport() {
    var ch = window[channelName];
    if (ch && typeof ch.postMessage === 'function') {
      return function(msg) { ch.postMessage(msg); };
    }
    var iaw = window.flutter_inappwebview;
    if (iaw && typeof iaw.callHandler === 'function') {
      return function(msg) { iaw.callHandler(channelName, msg); };
    }
    return null;
  }
  function bind(attempt) {
    var S = window.Scout || window.scout;
    var post = relay ? transport() : null;
    if (S && typeof S.setWebViewBridge === 'function' && (!relay || post)) {
      var bridge = {
        sessionId: nativeSessionId,
        anonymousId: nativeAnonymousId,
      };
      if (relay) {
        bridge.relay = true;
        bridge.send = function(payload) {
          try {
            post(typeof payload === 'string' ? payload : JSON.stringify(payload));
          } catch (_) {}
        };
      }
      try {
        S.setWebViewBridge(bridge);
        window.__SCOUT_WEBVIEW_BRIDGED = nativeSessionId;
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
