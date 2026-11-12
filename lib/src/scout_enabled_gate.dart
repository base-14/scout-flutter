import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// Drops every span that ends while RUM is disabled, before it reaches the
/// batch queue.
///
/// The sampler already drops spans started while disabled. This catches the
/// rest: spans started while enabled that end after `setEnabled(false)`.
/// Only spans that ended while enabled are queued, so flushing the queue on
/// disable sends nothing recorded after the switch, and nothing from the
/// disabled period is left to go out once RUM is enabled again.
class EnabledGatedSpanProcessor implements SpanProcessor {
  final SpanProcessor _delegate;
  final bool Function() _isEnabled;

  EnabledGatedSpanProcessor(
    this._delegate, {
    required bool Function() isEnabled,
  }) : _isEnabled = isEnabled;

  @override
  Future<void> onStart(Span span, Context? parentContext) =>
      _delegate.onStart(span, parentContext);

  @override
  Future<void> onEnd(Span span) async {
    if (!_isEnabled()) return;
    await _delegate.onEnd(span);
  }

  @override
  Future<void> onNameUpdate(Span span, String newName) =>
      _delegate.onNameUpdate(span, newName);

  @override
  Future<void> forceFlush() => _delegate.forceFlush();

  @override
  Future<void> shutdown() => _delegate.shutdown();
}

/// Holds metric exports while RUM is disabled.
///
/// The periodic reader keeps exporting cumulative streams on every tick
/// even when nothing new was recorded, so gating the instruments alone
/// would still make OTLP requests. While [open] is false an export reports
/// success without sending anything.
class EnabledGatedMetricExporter implements MetricExporter {
  final MetricExporter _delegate;

  /// Closed after the disable-time flush, reopened on enable.
  bool open;

  EnabledGatedMetricExporter(this._delegate, {this.open = true});

  @override
  Future<bool> export(MetricData data) async {
    if (!open) return true;
    return _delegate.export(data);
  }

  @override
  Future<bool> forceFlush() async {
    if (!open) return true;
    return _delegate.forceFlush();
  }

  @override
  Future<bool> shutdown() => _delegate.shutdown();
}
