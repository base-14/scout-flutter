import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Where a session's sampling decision came from: `'user'` when the app
/// supplied a per-user value (`userSampling`), `'fallback'` when the
/// per-session `sessionSampleRate` roll decided.
const kSamplingSourceUser = 'user';
const kSamplingSourceFallback = 'fallback';

/// Whether a user change should end the current session and start a new one,
/// so the next user never inherits the previous user's sampling decision.
///
/// Going from anonymous to the first id keeps the session, and so does
/// re-setting the same id. The rotation only happens while user sampling is
/// "in play": the current session was decided by a user value, or a user
/// value is pending. Apps that never use the feature therefore see no extra
/// sessions.
bool shouldRotateOnIdentityChange({
  required String? previousUserId,
  required String? newUserId,
  required String currentSource,
  required bool? pending,
}) {
  if (previousUserId == null) return false;
  if (newUserId == previousUserId) return false;
  return currentSource == kSamplingSourceUser || pending != null;
}

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

  /// The app-supplied per-user value, read only when a session is created.
  /// `null` means no opinion, so the [sampleRate] roll decides.
  final bool? Function() _pendingUserSampling;

  String _sessionId;
  bool _isSampled;
  String _samplingSource = kSamplingSourceFallback;
  bool? _externalSampled;
  String? _externalSamplingSource;
  DateTime? _backgroundTimestamp;
  late DateTime _sessionStartTime;
  File? _storeFile;

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
    bool? Function()? pendingUserSampling,
  }) : assert(sampleRate >= 0.0 && sampleRate <= 100.0),
       assert(maxDurationMinutes >= 0),
       sampleRate = sampleRate.clamp(0.0, 100.0),
       _clock = clock ?? DateTime.now,
       _onSessionChanged = onSessionChanged,
       _pendingUserSampling = pendingUserSampling ?? _noUserSampling,
       _sessionId = '',
       _isSampled = false {
    _sessionId = _generateUuidV4();
    _resolveSampling();
    _sessionStartTime = _clock();
    _onSessionChanged?.call(_sessionId, _isSampled);
  }

  static bool? _noUserSampling() => null;

  Future<void> start({required Directory directory}) async {
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      _storeFile = File('${directory.path}/scout_session.json');
      if (await _storeFile!.exists()) {
        final raw = await _storeFile!.readAsString();
        final data = json.decode(raw) as Map<String, dynamic>;
        final id = data['id'] as String?;
        final startedAtMs = data['startedAt'] as int?;
        final lastActiveAtMs = data['lastActiveAt'] as int?;
        final sampled = data['sampled'] as bool?;
        final source = data['samplingSource'];
        if (id != null &&
            id.isNotEmpty &&
            startedAtMs != null &&
            lastActiveAtMs != null &&
            sampled != null) {
          final now = _clock();
          final startedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
          final lastActiveAt = DateTime.fromMillisecondsSinceEpoch(
            lastActiveAtMs,
          );
          final withinIdle =
              now.difference(lastActiveAt) < Duration(minutes: timeoutMinutes);
          final withinLifetime =
              maxDurationMinutes == 0 ||
              now.difference(startedAt) < Duration(minutes: maxDurationMinutes);
          if (withinIdle && withinLifetime) {
            _sessionId = id;
            _isSampled = sampled;
            // Records written before user-based sampling carry no source.
            _samplingSource =
                source == kSamplingSourceUser
                    ? kSamplingSourceUser
                    : kSamplingSourceFallback;
            _sessionStartTime = startedAt;
            _onSessionChanged?.call(_sessionId, _isSampled);
            unawaited(_persist());
            return;
          }
        }
      }
    } catch (_) {}
    unawaited(_persist());
  }

  Future<void> _persist() async {
    final f = _storeFile;
    if (f == null) return;
    try {
      final data = <String, Object>{
        'v': 1,
        'id': _sessionId,
        'startedAt': _sessionStartTime.millisecondsSinceEpoch,
        'lastActiveAt': _clock().millisecondsSinceEpoch,
        'sampled': _isSampled,
        'samplingSource': _samplingSource,
      };
      await f.writeAsString(json.encode(data));
    } catch (_) {}
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
  bool get isSampled => _externalSampled ?? _isSampled;

  /// Where the current session's decision came from: [kSamplingSourceUser]
  /// or [kSamplingSourceFallback]. Follows the native owner when its
  /// decision was adopted.
  String get samplingSource {
    if (_externalSampled != null) {
      return _externalSamplingSource ?? kSamplingSourceFallback;
    }
    return _samplingSource;
  }

  /// Logs and metrics are dropped only for sessions sampled out by the
  /// fallback roll. A user-"no" session still sends them; only its spans are
  /// dropped.
  bool get allowsLogsAndMetrics =>
      isSampled || samplingSource == kSamplingSourceUser;

  /// Follows a native owner's decision, which is not persisted here, because
  /// the owner persists it.
  void adoptExternalSampling(bool? sampled, {String? samplingSource}) {
    _externalSampled = sampled;
    _externalSamplingSource = sampled == null ? null : samplingSource;
  }

  /// Wall-clock time when the current session started. Rehydrated from
  /// disk on resume so it survives process restarts; reset on rotation.
  DateTime get sessionStartTime => _sessionStartTime;

  /// Call when the app moves to the background.
  void onBackground() {
    _backgroundTimestamp = _clock();
    unawaited(_persist());
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
    unawaited(_persist());
  }

  /// Generates a new session ID and re-rolls the sampling decision.
  void rotateSession() {
    _sessionId = _generateUuidV4();
    _resolveSampling();
    _sessionStartTime = _clock();
    _onSessionChanged?.call(_sessionId, _isSampled);
    unawaited(_persist());
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

  /// Decides the new session: the app's per-user value if one is pending,
  /// otherwise the [sampleRate] roll. Only called when a session is created.
  void _resolveSampling() {
    final user = _pendingUserSampling();
    if (user != null) {
      _isSampled = user;
      _samplingSource = kSamplingSourceUser;
    } else {
      _isSampled = _rollSampling();
      _samplingSource = kSamplingSourceFallback;
    }
  }

  /// Returns `true` if this session should be sampled.
  bool _rollSampling() {
    if (sampleRate >= 100.0) return true;
    if (sampleRate <= 0.0) return false;
    return _random.nextDouble() * 100.0 < sampleRate;
  }
}
