import 'dart:math';

/// Manages RUM session identity, rotation, and sampling.
///
/// Every span, metric, and log is tagged with [sessionId]. Sessions rotate
/// after the app returns from background and the inactivity [timeoutMinutes]
/// has elapsed. Sampling is decided per-session based on [sampleRate].
class SessionManager {
  /// Sample rate as a percentage (0.0 – 100.0).
  final double sampleRate;

  /// Duration of inactivity (in minutes) after which a new session is started.
  final int timeoutMinutes;

  final Random _random = Random.secure();

  final DateTime Function() _clock;

  String _sessionId;
  bool _isSampled;
  DateTime? _backgroundTimestamp;

  /// Creates a [SessionManager].
  ///
  /// [sampleRate] must be between 0.0 and 100.0 inclusive.
  /// [timeoutMinutes] defaults to 30 minutes.
  SessionManager({
    required double sampleRate,
    this.timeoutMinutes = 30,
    DateTime Function()? clock,
  }) : assert(sampleRate >= 0.0 && sampleRate <= 100.0),
       sampleRate = sampleRate.clamp(0.0, 100.0),
       _clock = clock ?? DateTime.now,
       _sessionId = '',
       _isSampled = false {
    _sessionId = _generateUuidV4();
    _isSampled = _rollSampling();
  }

  /// The current session ID (UUID v4).
  String get sessionId => _sessionId;

  /// Whether the current session is sampled.
  bool get isSampled => _isSampled;

  /// Call when the app moves to the background.
  void onBackground() {
    _backgroundTimestamp = _clock();
  }

  /// Call when the app returns to the foreground.
  ///
  /// If the elapsed time since [onBackground] exceeds [timeoutMinutes],
  /// the session is rotated.
  void onForeground() {
    final bg = _backgroundTimestamp;
    if (bg != null) {
      final elapsed = _clock().difference(bg);
      if (elapsed >= Duration(minutes: timeoutMinutes)) {
        rotateSession();
      }
    }
    _backgroundTimestamp = null;
  }

  /// Generates a new session ID and re-rolls the sampling decision.
  void rotateSession() {
    _sessionId = _generateUuidV4();
    _isSampled = _rollSampling();
  }

  /// Generates a UUID v4 string using [Random.secure].
  ///
  /// Format: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
  /// where y is one of 8, 9, a, b.
  String _generateUuidV4() {
    // Generate 16 random bytes.
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));

    // Set version to 4 (bits 4-7 of byte 6).
    bytes[6] = (bytes[6] & 0x0f) | 0x40;

    // Set variant to 10xx (bits 6-7 of byte 8).
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

    return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}-'
        '${hex(bytes[4])}${hex(bytes[5])}-'
        '${hex(bytes[6])}${hex(bytes[7])}-'
        '${hex(bytes[8])}${hex(bytes[9])}-'
        '${hex(bytes[10])}${hex(bytes[11])}${hex(bytes[12])}'
        '${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
  }

  /// Returns `true` if this session should be sampled.
  bool _rollSampling() {
    if (sampleRate >= 100.0) return true;
    if (sampleRate <= 0.0) return false;
    return _random.nextDouble() * 100.0 < sampleRate;
  }
}
