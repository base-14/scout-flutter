import 'dart:math';
import 'package:dio/dio.dart';
import 'scout_http_overrides.dart';

/// Dio interceptor for HTTP request tracking.
///
/// Only needed when Dio is configured with a custom HttpClientAdapter.
/// Default Dio users are already covered by ScoutHttpOverrides.
class ScoutDioInterceptor extends Interceptor {
  static const _kStartTimeKey = '_scout_start_time';

  final List<String>? firstPartyHosts;
  final void Function(HttpRequestData data) onRequestCompleted;
  final Random _random = Random.secure();

  ScoutDioInterceptor({
    this.firstPartyHosts,
    required this.onRequestCompleted,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_kStartTimeKey] = DateTime.now().millisecondsSinceEpoch;

    if (isFirstPartyHost(options.uri.host, firstPartyHosts)) {
      final traceId = _generateHex(32);
      final spanId = _generateHex(16);
      options.headers['traceparent'] = generateTraceparent(traceId, spanId);
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _report(response.requestOptions, statusCode: response.statusCode ?? 0);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _report(err.requestOptions,
        statusCode: err.response?.statusCode ?? 0, error: err.message);
    handler.next(err);
  }

  void _report(RequestOptions options,
      {required int statusCode, String? error}) {
    final startTime = options.extra[_kStartTimeKey] as int?;
    final durationMs = startTime != null
        ? DateTime.now().millisecondsSinceEpoch - startTime
        : 0;
    onRequestCompleted(HttpRequestData(
      method: options.method,
      url: options.uri,
      statusCode: statusCode,
      durationMs: durationMs,
      responseSize: 0,
      error: error,
    ));
  }

  String _generateHex(int length) {
    final bytes = List<int>.generate(length ~/ 2, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
