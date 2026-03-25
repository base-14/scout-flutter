import 'dart:collection';
import 'dart:convert';

/// Circular buffer of breadcrumbs for error context.
///
/// Keeps the last [maxBreadcrumbs] entries. Attached to error spans as JSON.
class BreadcrumbManager {
  static const int maxBreadcrumbs = 20;

  final _buffer = Queue<Map<String, dynamic>>();

  void record(String type, String message) {
    _buffer.add({
      'type': type,
      'message': message,
      'time': DateTime.now().toIso8601String(),
    });
    while (_buffer.length > maxBreadcrumbs) {
      _buffer.removeFirst();
    }
  }

  List<Map<String, dynamic>> get breadcrumbs =>
      List.unmodifiable(_buffer.toList());

  String toJsonString() => jsonEncode(breadcrumbs);

  void clear() => _buffer.clear();
}
