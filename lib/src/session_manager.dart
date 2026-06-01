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

  /// Maximum lifetime of a single session in minutes. When `> 0`, reads of
  /// [sessionId] check elapsed time since the current session started and
  /// rotate inline if the cap is exceeded. `0` disables the cap.
  final int maxDurationMinutes;

  final Random _random = Random.secure();

  final DateTime Function() _clock;

  final void Function(String sessionId, bool sampled)? _onSessionChanged;

  String _sessionId;
  bool _isSampled;
  DateTime? _backgroundTimestamp;
  late DateTime _sessionStartTime;

  /// Creates a [SessionManager].
  ///
  /// [sampleRate] must be between 0.0 and 100.0 inclusive.
  /// [timeoutMinutes] defaults to 30 minutes.
  /// [onSessionChanged] fires once on construction and on every rotation.
  SessionManager({
    required double sampleRate,
    this.timeoutMinutes = 30,
    this.maxDurationMinutes = 0,
    DateTime Function()? clock,
    void Function(String sessionId, bool sampled)? onSessionChanged,
  }) : assert(sampleRate >= 0.0 && sampleRate <= 100.0),
       assert(maxDurationMinutes >= 0),
       sampleRate = sampleRate.clamp(0.0, 100.0),
       _clock = clock ?? DateTime.now,
       _onSessionChanged = onSessionChanged,
       _sessionId = '',
       _isSampled = false {
    _sessionId = _generateUuidV4();
    _isSampled = _rollSampling();
    _sessionStartTime = _clock();
    _onSessionChanged?.call(_sessionId, _isSampled);
  }

  /// The current session ID (UUID v4). When [maxDurationMinutes] is `> 0`,
  /// reading this getter rotates the session if it has lived longer than the
  /// cap — the returned ID is then the new one.
  String get sessionId {
    if (maxDurationMinutes > 0 &&
        _clock().difference(_sessionStartTime) >=
            Duration(minutes: maxDurationMinutes)) {
      rotateSession();
    }
    return _sessionId;
  }

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
    _sessionStartTime = _clock();
    _onSessionChanged?.call(_sessionId, _isSampled);
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
