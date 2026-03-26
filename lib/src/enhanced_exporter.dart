import 'offline_queue.dart';
import 'scout_rum_config.dart';

/// A composable exporter wrapper that adds sampling, beforeSend filtering,
/// and offline queueing to any export function.
class EnhancedExporter {
  final Future<bool> Function(List<Map<String, dynamic>> events) innerExport;
  final bool Function() isSampled;
  final OfflineQueue queue;
  final String signal; // "spans", "metrics", or "logs"
  final BeforeSendCallback? beforeSend;

  EnhancedExporter({
    required this.innerExport,
    required this.isSampled,
    required this.queue,
    required this.signal,
    this.beforeSend,
  });

  Future<bool> export(List<Map<String, dynamic>> events) async {
    if (!isSampled()) return true;
    if (events.isEmpty) return true;

    // Apply beforeSend filter
    final filtered = <Map<String, dynamic>>[];
    for (final event in events) {
      final mapped = {...event, 'type': signal};
      final result = beforeSend != null ? beforeSend!(mapped) : mapped;
      if (result != null) {
        filtered.add(result);
      }
    }

    if (filtered.isEmpty) return true;

    final success = await innerExport(filtered);
    if (!success) {
      await queue.enqueue(signal, filtered);
    }
    return success;
  }
}
