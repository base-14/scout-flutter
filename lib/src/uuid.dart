import 'dart:math';

final _random = Random();

/// Generates a RFC 4122 v4 UUID using `dart:math`'s default PRNG.
/// Not cryptographic — fine for event/span identifiers but do not use
/// for security tokens. Inlined here (no `package:uuid` dep) to keep
/// the SDK's transitive dependency list short.
String uuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx

  String h(int b) => b.toRadixString(16).padLeft(2, '0');
  return '${h(bytes[0])}${h(bytes[1])}${h(bytes[2])}${h(bytes[3])}-'
      '${h(bytes[4])}${h(bytes[5])}-'
      '${h(bytes[6])}${h(bytes[7])}-'
      '${h(bytes[8])}${h(bytes[9])}-'
      '${h(bytes[10])}${h(bytes[11])}${h(bytes[12])}${h(bytes[13])}${h(bytes[14])}${h(bytes[15])}';
}

/// Stable djb2 hash of [input], rendered as an 8-char hex string.
/// Used for `*.fingerprint` / `*.permanent_id` fields where we need
/// the same logical thing to hash to the same value across sessions.
String djb2Hash(String input) {
  int h = 5381;
  for (var i = 0; i < input.length; i++) {
    h = ((h * 33) ^ input.codeUnitAt(i)) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
