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

  OfflineQueue({required this.directory, required this.maxStorageMb});

  /// Write a batch of events to a timestamped file.
  Future<void> enqueue(String signal, List<Map<String, dynamic>> events) async {
    try {
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${directory.path}/${signal}_$timestamp.jsonl');
      final lines = events.map((e) => jsonEncode(e)).join('\n');
      await file.writeAsString(lines);
      await enforceStorageCap();
    } catch (_) {
      // Never crash the app due to offline queue failure.
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
