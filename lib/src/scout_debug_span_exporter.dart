import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'scout_debug_logger.dart';

class ScoutDebugSpanExporter implements SpanExporter {
  final SpanExporter _inner;
  final ScoutDebugLogger _logger;

  ScoutDebugSpanExporter(this._inner, this._logger);

  @override
  Future<void> export(List<Span> spans) async {
    final sw = Stopwatch()..start();
    try {
      await _inner.export(spans);
      _logger.exportBatch(
        spans: spans.length,
        durationMs: sw.elapsedMilliseconds,
        ok: true,
      );
    } catch (e) {
      _logger.exportBatch(
        spans: spans.length,
        durationMs: sw.elapsedMilliseconds,
        ok: false,
        error: e.toString(),
      );
      rethrow;
    }
  }

  @override
  Future<void> forceFlush() => _inner.forceFlush();

  @override
  Future<void> shutdown() => _inner.shutdown();
}
