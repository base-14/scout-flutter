import 'dart:async';

import 'fixed_http_log_exporter.dart';

/// Batches log records the same way spans and metrics are batched:
/// buffer up to [maxQueueSize] (drop beyond), flush every [interval] or
/// as soon as [maxExportBatchSize] records are buffered, one delivery
/// attempt per batch (at-most-once — failed batches go to
/// [onExportFailed] and are never re-sent by the batcher).
///
/// Previously every log entry was exported in its own HTTP POST, so a
/// chatty app produced one request per log line.
class ScoutLogBatcher {
  final Future<bool> Function(List<ScoutLogRecord> batch) export;

  /// Invoked with a batch the exporter rejected. The caller decides
  /// what durability (if any) to give it — e.g. the offline queue.
  final void Function(List<ScoutLogRecord> batch)? onExportFailed;

  final Duration interval;
  final int maxExportBatchSize;
  final int maxQueueSize;

  final List<ScoutLogRecord> _buffer = [];
  Timer? _timer;
  bool _flushing = false;

  ScoutLogBatcher({
    required this.export,
    this.onExportFailed,
    required this.interval,
    required this.maxExportBatchSize,
    required this.maxQueueSize,
  });

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Buffer a record. Drops it when the queue is full; triggers an
  /// immediate flush when the buffer reaches one full batch.
  void add(ScoutLogRecord record) {
    if (_buffer.length >= maxQueueSize) return;
    _buffer.add(record);
    if (_buffer.length >= maxExportBatchSize) {
      unawaited(flush());
    }
  }

  /// Drain the buffer in batches of [maxExportBatchSize]. Each batch
  /// gets one delivery attempt; on failure the batch goes to
  /// [onExportFailed] and the remaining buffer waits for the next tick
  /// (so a struggling collector isn't hammered).
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    try {
      while (_buffer.isNotEmpty) {
        final size =
            _buffer.length > maxExportBatchSize
                ? maxExportBatchSize
                : _buffer.length;
        final batch = _buffer.sublist(0, size);
        _buffer.removeRange(0, size);
        var ok = false;
        try {
          ok = await export(batch);
        } catch (_) {
          ok = false;
        }
        if (!ok) {
          try {
            onExportFailed?.call(batch);
          } catch (_) {}
          break;
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
