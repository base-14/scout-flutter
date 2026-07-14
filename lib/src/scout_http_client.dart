import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// A keep-alive HTTP client for exporters.
///
/// The top-level `http.post(...)` convenience function creates and closes
/// a new `Client` per call — a fresh TCP + TLS handshake for every beacon,
/// which makes the server re-send its certificate chain (~4–5 KB) on each
/// request. Holding one client per exporter amortizes the handshake to
/// once per app session.
///
/// [idleTimeout] must exceed the export interval or the kept-alive
/// connection dies between ticks (dart:io's default is only 15 s).
http.Client buildScoutHttpClient({
  Duration idleTimeout = const Duration(seconds: 65),
}) {
  return IOClient(HttpClient()..idleTimeout = idleTimeout);
}
