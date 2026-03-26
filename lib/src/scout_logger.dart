/// Log severity levels matching OpenTelemetry severity numbers.
enum LogLevel {
  debug(5, 'DEBUG'),
  info(9, 'INFO'),
  warning(13, 'WARN'),
  error(17, 'ERROR');

  final int severityNumber;
  final String severityText;
  const LogLevel(this.severityNumber, this.severityText);
}

/// A log entry captured by ScoutLogger.
class ScoutLogEntry {
  final LogLevel level;
  final String message;
  final DateTime timestamp;
  final Map<String, Object>? attributes;

  ScoutLogEntry({
    required this.level,
    required this.message,
    required this.timestamp,
    this.attributes,
  });
}

/// Internal logger that forwards log entries via callback.
class ScoutLogger {
  final void Function(ScoutLogEntry entry) _onLog;

  ScoutLogger({required void Function(ScoutLogEntry entry) onLog})
    : _onLog = onLog;

  void log(LogLevel level, String message, {Map<String, Object>? attributes}) {
    _onLog(
      ScoutLogEntry(
        level: level,
        message: message,
        timestamp: DateTime.now(),
        attributes: attributes,
      ),
    );
  }

  void logDebug(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.debug, message, attributes: attributes);

  void logInfo(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.info, message, attributes: attributes);

  void logWarning(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.warning, message, attributes: attributes);

  void logError(String message, {Map<String, Object>? attributes}) =>
      log(LogLevel.error, message, attributes: attributes);
}
