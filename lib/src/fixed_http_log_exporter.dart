// ignore_for_file: implementation_imports
// MetricTransformer is not publicly exported by dartastic_opentelemetry.
// This import is required to reuse transformResource for building the
// protobuf Resource message. Same workaround as fixed_http_metric_exporter.

import 'dart:math';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/src/metrics/export/otlp/metric_transformer.dart';
import 'package:dartastic_opentelemetry/proto/collector/logs/v1/logs_service.pb.dart';
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart'
    as common_pb;
import 'package:dartastic_opentelemetry/proto/logs/v1/logs.pb.dart'
    as logs_pb;
import 'package:dartastic_opentelemetry/proto/logs/v1/logs.pbenum.dart'
    as logs_enum;
import 'package:fixnum/fixnum.dart';
import 'package:http/http.dart' as http;

/// A log record to be exported via OTLP.
class ScoutLogRecord {
  final int severityNumber;
  final String severityText;
  final String body;
  final BigInt timestampNanos;
  final Map<String, Object>? attributes;
  final String? traceId;
  final String? spanId;

  ScoutLogRecord({
    required this.severityNumber,
    required this.severityText,
    required this.body,
    required this.timestampNanos,
    this.attributes,
    this.traceId,
    this.spanId,
  });
}

/// OTLP HTTP log exporter that POSTs protobuf-encoded log data to /v1/logs.
///
/// Follows the same pattern as [FixedHttpMetricExporter]: endpoint
/// normalisation, jittered exponential backoff on retryable failures, and
/// the frozen-proto workaround for InstrumentationScope.
class FixedHttpLogExporter {
  final String _endpoint;
  final Map<String, String> _headers;
  final Duration _timeout;
  final int _maxRetries;
  final Duration _baseDelay;
  bool _isShutdown = false;
  final Random _random = Random();

  FixedHttpLogExporter({
    required String endpoint,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 3,
    Duration baseDelay = const Duration(milliseconds: 200),
  })  : _endpoint = endpoint.endsWith('/v1/logs')
            ? endpoint
            : '${endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint}/v1/logs',
        _headers = headers ?? {},
        _timeout = timeout,
        _maxRetries = maxRetries,
        _baseDelay = baseDelay;

  /// Exports a list of [ScoutLogRecord]s to the configured OTLP endpoint.
  ///
  /// Returns `true` on success or if the list is empty, `false` on failure
  /// or after [shutdown] has been called.
  Future<bool> export(List<ScoutLogRecord> logs) async {
    if (_isShutdown) return false;
    if (logs.isEmpty) return true;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _tryExport(logs);
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

  Future<bool> _tryExport(List<ScoutLogRecord> logs) async {
    final request = ExportLogsServiceRequest();
    final resourceLogs = logs_pb.ResourceLogs();

    // Use OTel.defaultResource if available (same fallback as metric exporter).
    final resource = OTel.defaultResource;
    if (resource != null) {
      resourceLogs.resource = MetricTransformer.transformResource(resource);
    }

    final scopeLogs = logs_pb.ScopeLogs();

    // Fix: create a new InstrumentationScope instead of mutating the frozen default.
    final scope = common_pb.InstrumentationScope();
    scope.name = 'scout_flutter';
    scope.version = '0.1.0';
    scopeLogs.scope = scope;

    for (final log in logs) {
      final logRecord = logs_pb.LogRecord();

      // Timestamp
      logRecord.timeUnixNano = Int64.parseInt(log.timestampNanos.toString());
      logRecord.observedTimeUnixNano =
          Int64.parseInt(log.timestampNanos.toString());

      // Severity
      final severityEnum =
          logs_enum.SeverityNumber.valueOf(log.severityNumber);
      if (severityEnum != null) {
        logRecord.severityNumber = severityEnum;
      }
      logRecord.severityText = log.severityText;

      // Body
      final bodyValue = common_pb.AnyValue();
      bodyValue.stringValue = log.body;
      logRecord.body = bodyValue;

      // Attributes
      if (log.attributes != null) {
        for (final entry in log.attributes!.entries) {
          final kv = common_pb.KeyValue();
          kv.key = entry.key;
          kv.value = _toAnyValue(entry.value);
          logRecord.attributes.add(kv);
        }
      }

      // Trace context
      if (log.traceId != null) {
        logRecord.traceId = _hexToBytes(log.traceId!);
      }
      if (log.spanId != null) {
        logRecord.spanId = _hexToBytes(log.spanId!);
      }

      scopeLogs.logRecords.add(logRecord);
    }

    resourceLogs.scopeLogs.add(scopeLogs);
    request.resourceLogs.add(resourceLogs);

    final headers = Map<String, String>.from(_headers);
    headers['Content-Type'] = 'application/x-protobuf';

    final Uint8List bodyBytes = request.writeToBuffer();

    final response = await http
        .post(Uri.parse(_endpoint), headers: headers, body: bodyBytes)
        .timeout(_timeout);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return true;
    }
    throw http.ClientException(
      'Export failed with status code ${response.statusCode}',
    );
  }

  Duration _jitteredDelay(int attempt) {
    final baseMs = _baseDelay.inMilliseconds;
    final delay = baseMs * pow(2, attempt);
    return Duration(
        milliseconds: (delay + _random.nextDouble() * delay).toInt());
  }

  static const _retryableStatusCodes = [429, 503];

  /// No-op flush — logs are exported immediately.
  Future<bool> forceFlush() async => true;

  /// Marks this exporter as shut down. Subsequent [export] calls return false.
  Future<bool> shutdown() async {
    _isShutdown = true;
    return true;
  }

  /// Converts a Dart [Object] value to a protobuf [common_pb.AnyValue].
  static common_pb.AnyValue _toAnyValue(Object value) {
    final av = common_pb.AnyValue();
    if (value is String) {
      av.stringValue = value;
    } else if (value is int) {
      av.intValue = Int64(value);
    } else if (value is double) {
      av.doubleValue = value;
    } else if (value is bool) {
      av.boolValue = value;
    } else {
      av.stringValue = value.toString();
    }
    return av;
  }

  /// Converts a hex string (e.g. trace ID, span ID) to a list of bytes.
  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
