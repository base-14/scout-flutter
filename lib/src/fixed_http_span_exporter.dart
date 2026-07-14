import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;

import 'scout_http_client.dart';

/// OTLP HTTP span exporter with a persistent keep-alive connection.
///
/// Replaces the upstream `OtlpHttpSpanExporter`, which posts every batch
/// through the top-level `http.post` — a new TCP + TLS handshake per
/// export. This exporter holds one client for the exporter's lifetime,
/// so the handshake happens once per app session instead of per beacon.
///
/// Delivery is at-most-once by default (`maxRetries: 0`): retrying an
/// ambiguous failure (a timeout whose request the collector may already
/// have ingested) delivers duplicate spans with identical span IDs.
class FixedHttpSpanExporter implements SpanExporter {
  final String _endpoint;
  final Map<String, String> _headers;
  final Duration _timeout;
  final int _maxRetries;
  final http.Client _client;
  bool _isShutdown = false;

  FixedHttpSpanExporter({
    required String endpoint,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 0,
    Duration idleTimeout = const Duration(seconds: 65),
    http.Client? client,
  }) : _endpoint =
           endpoint.endsWith('/v1/traces')
               ? endpoint
               : '${endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint}/v1/traces',
       _headers = headers ?? {},
       _timeout = timeout,
       _maxRetries = maxRetries,
       _client = client ?? buildScoutHttpClient(idleTimeout: idleTimeout);

  @override
  Future<void> export(List<Span> spans) async {
    if (_isShutdown || spans.isEmpty) return;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (await _tryExport(spans)) return;
      if (attempt >= _maxRetries) return;
    }
  }

  Future<bool> _tryExport(List<Span> spans) async {
    try {
      final request = OtlpSpanTransformer.transformSpans(spans);
      final headers = Map<String, String>.from(_headers);
      headers['Content-Type'] = 'application/x-protobuf';
      final Uint8List bodyBytes = request.writeToBuffer();

      final response = await _client
          .post(Uri.parse(_endpoint), headers: headers, body: bodyBytes)
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    _isShutdown = true;
    _client.close();
  }
}
