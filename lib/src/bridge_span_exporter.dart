import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'scout_platform_channel.dart';

class BridgeSpanExporter implements SpanExporter {
  final String scopeName;

  BridgeSpanExporter(this.scopeName);

  @override
  Future<void> export(List<Span> spans) async {
    if (spans.isEmpty) return;
    final out = <Map<String, Object?>>[];
    for (final s in spans) {
      if (s.name == 'app_lifecycle.changed') continue;
      final attrs = <String, String>{};
      // ignore: invalid_use_of_visible_for_testing_member
      for (final e in s.attributes.toMap().entries) {
        if (e.key.startsWith('session.') || e.key.startsWith('user.')) continue;
        attrs[e.key] = e.value.value.toString();
      }
      final start = s.startTime.microsecondsSinceEpoch * 1000;
      final end = (s.endTime ?? s.startTime).microsecondsSinceEpoch * 1000;
      out.add({
        'scope': scopeName,
        'name': s.name,
        'kind': _kind(s.kind),
        'trace_id': s.spanContext.traceId.toString(),
        'span_id': s.spanContext.spanId.toString(),
        'parent_span_id': s.parentSpanContext?.spanId.toString(),
        'start_unix_nano': start.toString(),
        'end_unix_nano': end.toString(),
        'attributes': attrs,
        'status': {'code': _status(s.status), 'message': s.statusDescription},
      });
    }
    await ScoutPlatformChannel.ingestSpans(jsonEncode({'spans': out}));
  }

  String _kind(SpanKind k) {
    switch (k) {
      case SpanKind.client:
        return 'CLIENT';
      case SpanKind.server:
        return 'SERVER';
      default:
        return 'INTERNAL';
    }
  }

  String _status(SpanStatusCode s) {
    switch (s) {
      case SpanStatusCode.Error:
        return 'ERROR';
      case SpanStatusCode.Ok:
        return 'OK';
      default:
        return 'UNSET';
    }
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}
