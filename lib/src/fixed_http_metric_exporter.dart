// ignore_for_file: implementation_imports
// MetricTransformer is not publicly exported by dartastic_opentelemetry.
// This import is required to work around the frozen protobuf bug in
// OtlpHttpMetricExporter. Remove when upstream issue is fixed:
// https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/1

import 'dart:math';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/src/metrics/export/otlp/metric_transformer.dart';
import 'package:dartastic_opentelemetry/proto/collector/metrics/v1/metrics_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart'
    as common_pb;
import 'package:dartastic_opentelemetry/proto/metrics/v1/metrics.pb.dart'
    as metrics_pb;
import 'package:http/http.dart' as http;

/// A fixed version of OtlpHttpMetricExporter that correctly creates
/// InstrumentationScope as a new message instead of mutating the frozen default.
///
/// Works around https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/1
/// Remove this once the upstream bug is fixed.
class FixedHttpMetricExporter implements MetricExporter {
  final String _endpoint;
  final Map<String, String> _headers;
  final Duration _timeout;
  final int _maxRetries;
  final Duration _baseDelay;
  bool _isShutdown = false;
  final Random _random = Random();

  FixedHttpMetricExporter({
    required String endpoint,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 3,
    Duration baseDelay = const Duration(milliseconds: 200),
  }) : _endpoint =
           endpoint.endsWith('/v1/metrics')
               ? endpoint
               : '${endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint}/v1/metrics',
       _headers = headers ?? {},
       _timeout = timeout,
       _maxRetries = maxRetries,
       _baseDelay = baseDelay;

  @override
  Future<bool> export(MetricData data) async {
    if (_isShutdown) return false;
    if (data.metrics.isEmpty) return true;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _tryExport(data);
      } on http.ClientException catch (e) {
        if (attempt >= _maxRetries) return false;
        final isRetryable = _retryableStatusCodes.any(
          (code) => e.message.contains('status code $code'),
        );
        if (!isRetryable) return false;
        await Future<void>.delayed(_jitteredDelay(attempt));
      } catch (_) {
        if (attempt >= _maxRetries) return false;
        await Future<void>.delayed(_jitteredDelay(attempt));
      }
    }
    return false;
  }

  Future<bool> _tryExport(MetricData metrics) async {
    final request = ExportMetricsServiceRequest();
    final resourceMetrics = metrics_pb.ResourceMetrics();

    // Use the metric data's resource if available, otherwise fall back to
    // OTel.defaultResource. The fallback is needed because UIMeterProvider's
    // resource setter is a no-op (upstream bug in flutterrific_opentelemetry),
    // so MetricData.resource is always null.
    final resource = metrics.resource ?? OTel.defaultResource;
    if (resource != null) {
      resourceMetrics.resource = MetricTransformer.transformResource(resource);
    }

    final scopeMetrics = metrics_pb.ScopeMetrics();

    // Fix: create a new InstrumentationScope instead of mutating the frozen default.
    final scope = common_pb.InstrumentationScope();
    scope.name = '@dart/dartastic_opentelemetry';
    scope.version = '1.0.0';
    scopeMetrics.scope = scope;

    for (final metric in metrics.metrics) {
      scopeMetrics.metrics.add(MetricTransformer.transformMetric(metric));
    }

    resourceMetrics.scopeMetrics.add(scopeMetrics);
    request.resourceMetrics.add(resourceMetrics);

    final headers = Map<String, String>.from(_headers);
    headers['Content-Type'] = 'application/x-protobuf';

    final Uint8List bodyBytes = request.writeToBuffer();

    try {
      final response = await http
          .post(Uri.parse(_endpoint), headers: headers, body: bodyBytes)
          .timeout(_timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      throw http.ClientException(
        'Export failed with status code ${response.statusCode}',
      );
    } catch (e) {
      return false;
    }
  }

  Duration _jitteredDelay(int attempt) {
    final baseMs = _baseDelay.inMilliseconds;
    final delay = baseMs * pow(2, attempt);
    return Duration(
      milliseconds: (delay + _random.nextDouble() * delay).toInt(),
    );
  }

  static const _retryableStatusCodes = [429, 503];

  @override
  Future<bool> forceFlush() async => true;

  @override
  Future<bool> shutdown() async {
    _isShutdown = true;
    return true;
  }
}
