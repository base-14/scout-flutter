import 'dart:convert';
import 'dart:io';

class OfflineBatch {
  final String signal;
  final List<Map<String, dynamic>> events;
  OfflineBatch({required this.signal, required this.events});
}

class OfflineQueue {
  final Directory directory;
  final int maxStorageMb;
  final bool enabled;

  /// Per-signal item cap. Lookup keys: `'traces'`, `'metrics'`, `'logs'`.
  /// When a signal exceeds its cap, oldest batches for that signal are
  /// FIFO-evicted until the cap is satisfied. A cap of 0 disables that
  /// signal entirely.
  final Map<String, int> maxItemsPerSignal;

  OfflineQueue({
    required this.directory,
    required this.maxStorageMb,
    this.enabled = true,
    Map<String, int>? maxItemsPerSignal,
  }) : maxItemsPerSignal =
           maxItemsPerSignal ??
           const {'traces': 5000, 'metrics': 2000, 'logs': 5000};

  /// Write a batch of events to a timestamped file.
  Future<void> enqueue(String signal, List<Map<String, dynamic>> events) async {
    if (!enabled) return;
    // Unknown signal names fall back to a sane default so the queue
    // stays usable for custom signal types without explicit caps.
    final cap = maxItemsPerSignal[signal] ?? 5000;
    if (cap <= 0) return;
    try {
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${directory.path}/${signal}_$timestamp.jsonl');
      final lines = events.map((e) => jsonEncode(e)).join('\n');
      await file.writeAsString(lines);
      await _enforcePerSignalCap(signal, cap);
      await enforceStorageCap();
    } catch (_) {
      // Never crash the app due to offline queue failure.
    }
  }

  /// Count items across all batches for one signal; FIFO-evict oldest
  /// files until total items ≤ cap. One batch may itself exceed the
  /// cap — in that case it survives (we never drop the only batch).
  Future<void> _enforcePerSignalCap(String signal, int cap) async {
    if (!directory.existsSync()) return;
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.jsonl') &&
                  f.uri.pathSegments.last.startsWith('${signal}_'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (files.length <= 1) return;

    // Item count per file = newline-separated entries. Cheap to compute.
    final counts = <File, int>{
      for (final f in files)
        f: '\n'.allMatches(await f.readAsString()).length + 1,
    };
    var total = counts.values.fold<int>(0, (s, n) => s + n);
    var i = 0;
    while (total > cap && i < files.length - 1) {
      total -= counts[files[i]]!;
      try {
        await files[i].delete();
      } catch (_) {}
      i++;
    }
  }

  /// Read all queued batches, delete the files, return the data.
  Future<List<OfflineBatch>> dequeueAll() async {
    if (!directory.existsSync()) return [];
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jsonl'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)); // oldest first

    final batches = <OfflineBatch>[];
    for (final file in files) {
      try {
        final content = await file.readAsString();
        final lines = content.split('\n').where((l) => l.isNotEmpty);
        final events =
            lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
        final fileName = file.uri.pathSegments.last;
        final signal = fileName.split('_').first;
        batches.add(OfflineBatch(signal: signal, events: events));
        await file.delete();
      } catch (_) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    return batches;
  }

  /// Delete oldest files until total size <= maxStorageMb.
  Future<void> enforceStorageCap() async {
    if (!directory.existsSync()) return;
    final maxBytes = maxStorageMb * 1024 * 1024;
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jsonl'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)); // oldest first

    var totalSize = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    var i = 0;
    while (totalSize > maxBytes && i < files.length) {
      totalSize -= files[i].lengthSync();
      files[i].deleteSync();
      i++;
    }
  }
}
