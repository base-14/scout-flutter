import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'scout_http_overrides.dart';

/// Generates a random hex string of [bytes] length (each byte = 2 hex chars).
String _randomHex(int bytes) {
  final rng = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// An [HttpClient] wrapper that tracks HTTP requests and injects
/// W3C traceparent headers for first-party hosts.
class ScoutTrackingHttpClient implements HttpClient {
  final HttpClient inner;
  final String exportEndpoint;
  final List<RegExp>? ignorePatterns;
  final List<String>? firstPartyHosts;
  final void Function(HttpRequestData data) onRequestCompleted;
  final void Function(String traceId, String spanId)? onTraceContextCreated;

  ScoutTrackingHttpClient({
    required this.inner,
    required this.exportEndpoint,
    required this.onRequestCompleted,
    this.ignorePatterns,
    this.firstPartyHosts,
    this.onTraceContextCreated,
  });

  // --- Properties: delegate to inner ---

  @override
  Duration get idleTimeout => inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => inner.autoUncompress;
  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;

  @override
  String? get userAgent => inner.userAgent;
  @override
  set userAgent(String? value) => inner.userAgent = value;

  // --- Write-only setters: delegate to inner ---

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => inner.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(
      String host,
      int port,
      String scheme,
      String? realm,
    )? f,
  ) => inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => inner.badCertificateCallback = callback;

  @override
  set findProxy(String Function(Uri url)? f) => inner.findProxy = f;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) => inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => inner.keyLog = callback;

  // --- Credential methods ---

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => inner.addProxyCredentials(host, port, realm, credentials);

  // --- close ---

  @override
  void close({bool force = false}) => inner.close(force: force);

  // --- Core: openUrl with tracking ---

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (!shouldTrackUrl(
      url,
      exportEndpoint: exportEndpoint,
      ignorePatterns: ignorePatterns,
    )) {
      return inner.openUrl(method, url);
    }

    final stopwatch = Stopwatch()..start();
    final request = await inner.openUrl(method, url);

    // Inject traceparent for first-party hosts.
    if (isFirstPartyHost(url.host, firstPartyHosts)) {
      final traceId = _randomHex(16); // 32 hex chars
      final spanId = _randomHex(8); // 16 hex chars
      request.headers.set('traceparent', generateTraceparent(traceId, spanId));
      onTraceContextCreated?.call(traceId, spanId);
    }

    return _TrackedHttpClientRequest(
      inner: request,
      method: method,
      url: url,
      stopwatch: stopwatch,
      onRequestCompleted: onRequestCompleted,
    );
  }

  // --- open delegates to openUrl ---

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    const int hashMark = 0x23;
    const int questionMark = 0x3f;
    String fragmentPart = '';
    String queryPart = '';
    int queryStart = path.length;
    for (int i = 0; i < path.length; i++) {
      final char = path.codeUnitAt(i);
      if (char == hashMark) {
        fragmentPart = path.substring(i + 1);
        queryStart = i;
        break;
      }
      if (char == questionMark) {
        queryStart = i;
      }
    }
    if (queryStart < path.length && fragmentPart.isEmpty) {
      queryPart = path.substring(queryStart + 1);
      path = path.substring(0, queryStart);
    } else if (queryStart < path.length) {
      // find query between queryStart and fragmentStart
      for (int i = 0; i < queryStart; i++) {
        if (path.codeUnitAt(i) == questionMark) {
          queryPart = path.substring(i + 1, queryStart);
          path = path.substring(0, i);
          break;
        }
      }
      if (queryPart.isEmpty) {
        path = path.substring(0, queryStart);
      }
    }
    final uri = Uri(
      scheme: port == 443 ? 'https' : 'http',
      host: host,
      port: port,
      path: path,
      query: queryPart.isEmpty ? null : queryPart,
      fragment: fragmentPart.isEmpty ? null : fragmentPart,
    );
    return openUrl(method, uri);
  }

  // --- Convenience methods: all delegate to openUrl ---

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
}

/// A wrapper around [HttpClientRequest] that tracks timing and reports
/// request data when the response completes.
class _TrackedHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest inner;
  final String _trackingMethod;
  final Uri _trackingUrl;
  final Stopwatch _stopwatch;
  final void Function(HttpRequestData data) _onRequestCompleted;

  _TrackedHttpClientRequest({
    required this.inner,
    required String method,
    required Uri url,
    required Stopwatch stopwatch,
    required void Function(HttpRequestData data) onRequestCompleted,
  })  : _trackingMethod = method,
        _trackingUrl = url,
        _stopwatch = stopwatch,
        _onRequestCompleted = onRequestCompleted;

  // --- Properties: delegate to inner ---

  @override
  bool get bufferOutput => inner.bufferOutput;
  @override
  set bufferOutput(bool value) => inner.bufferOutput = value;

  @override
  int get contentLength => inner.contentLength;
  @override
  set contentLength(int value) => inner.contentLength = value;

  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) => inner.encoding = value;

  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;

  @override
  int get maxRedirects => inner.maxRedirects;
  @override
  set maxRedirects(int value) => inner.maxRedirects = value;

  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  set persistentConnection(bool value) => inner.persistentConnection = value;

  // --- Read-only properties ---

  @override
  HttpHeaders get headers => inner.headers;

  @override
  HttpConnectionInfo? get connectionInfo => inner.connectionInfo;

  @override
  List<Cookie> get cookies => inner.cookies;

  @override
  Future<HttpClientResponse> get done => inner.done;

  @override
  String get method => inner.method;

  @override
  Uri get uri => inner.uri;

  // --- IOSink methods ---

  @override
  void add(List<int> data) => inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => inner.addStream(stream);

  @override
  void write(Object? object) => inner.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => inner.writeln(object);

  @override
  Future flush() => inner.flush();

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      inner.abort(exception, stackTrace);

  // --- close: track and report ---

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await inner.close();
      _stopwatch.stop();
      _onRequestCompleted(HttpRequestData(
        method: _trackingMethod,
        url: _trackingUrl,
        statusCode: response.statusCode,
        durationMs: _stopwatch.elapsedMilliseconds,
        responseSize: response.contentLength < 0 ? 0 : response.contentLength,
      ));
      return response;
    } catch (e) {
      _stopwatch.stop();
      _onRequestCompleted(HttpRequestData(
        method: _trackingMethod,
        url: _trackingUrl,
        statusCode: 0,
        durationMs: _stopwatch.elapsedMilliseconds,
        responseSize: 0,
        error: e.toString(),
      ));
      rethrow;
    }
  }
}
