import 'dart:convert';
import 'dart:io';

/// Detects app crashes by persisting session state to disk and checking
/// on next launch whether the previous session exited cleanly.
class CrashDetector {
  static const _markerFileName = 'session_marker.json';
  static const _breadcrumbFileName = 'breadcrumbs.json';

  final Directory _directory;

  CrashDetector({required Directory directory}) : _directory = directory;

  File get _markerFile => File('${_directory.path}/$_markerFileName');
  File get _breadcrumbFile => File('${_directory.path}/$_breadcrumbFileName');

  /// Checks for a crash from the previous session.
  ///
  /// Returns a [CrashReport] if the previous session did not exit cleanly,
  /// or `null` if the previous session ended normally (or no marker exists).
  Future<CrashReport?> checkPreviousCrash() async {
    try {
      final file = _markerFile;
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final data = json.decode(content) as Map<String, dynamic>;
      final status = data['status'] as String?;

      // "paused" means the app went to background normally — not a crash.
      if (status == 'paused') {
        await file.delete();
        try {
          if (await _breadcrumbFile.exists()) await _breadcrumbFile.delete();
        } catch (_) {}
        return null;
      }

      // "started" means the app was in foreground and never paused — crash.
      // Read persisted breadcrumbs from the crashed session.
      String? breadcrumbs;
      try {
        if (await _breadcrumbFile.exists()) {
          breadcrumbs = await _breadcrumbFile.readAsString();
          await _breadcrumbFile.delete();
        }
      } catch (_) {}

      final report = CrashReport(
        sessionId: data['session_id'] as String? ?? 'unknown',
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          data['started_at'] as int? ?? 0,
        ),
        lastScreen: data['last_screen'] as String?,
        status: status ?? 'unknown',
        breadcrumbs: breadcrumbs,
      );

      await file.delete();
      return report;
    } catch (_) {
      // Corrupted marker — delete and move on.
      try {
        await _markerFile.delete();
      } catch (_) {}
      return null;
    }
  }

  /// Writes a new session marker indicating the app is running.
  Future<void> markSessionStarted({
    required String sessionId,
    String? screen,
  }) async {
    await _write({
      'session_id': sessionId,
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'status': 'started',
      if (screen != null) 'last_screen': screen,
    });
  }

  /// Updates the marker to "paused" — indicates a clean background transition.
  Future<void> markSessionPaused() async {
    await _updateStatus('paused');
  }

  /// Updates the marker back to "started" when returning to foreground.
  Future<void> markSessionResumed() async {
    await _updateStatus('started');
  }

  /// Persists breadcrumbs to disk so they survive a crash.
  /// Called periodically by the SDK.
  Future<void> persistBreadcrumbs(String breadcrumbsJson) async {
    try {
      if (!await _directory.exists()) {
        await _directory.create(recursive: true);
      }
      await _breadcrumbFile.writeAsString(breadcrumbsJson);
    } catch (_) {}
  }

  /// Updates the last known screen in the marker.
  Future<void> updateLastScreen(String screen) async {
    try {
      final file = _markerFile;
      if (!await file.exists()) return;
      final data =
          json.decode(await file.readAsString()) as Map<String, dynamic>;
      data['last_screen'] = screen;
      await _write(data);
    } catch (_) {}
  }

  Future<void> _updateStatus(String status) async {
    try {
      final file = _markerFile;
      if (!await file.exists()) return;
      final data =
          json.decode(await file.readAsString()) as Map<String, dynamic>;
      data['status'] = status;
      await _write(data);
    } catch (_) {}
  }

  Future<void> _write(Map<String, dynamic> data) async {
    try {
      if (!await _directory.exists()) {
        await _directory.create(recursive: true);
      }
      await _markerFile.writeAsString(json.encode(data));
    } catch (_) {}
  }
}

/// Info about a crash detected from the previous session.
class CrashReport {
  final String sessionId;
  final DateTime startedAt;
  final String? lastScreen;
  final String status;
  final String? breadcrumbs;

  CrashReport({
    required this.sessionId,
    required this.startedAt,
    this.lastScreen,
    required this.status,
    this.breadcrumbs,
  });
}
