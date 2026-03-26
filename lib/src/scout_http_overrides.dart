import 'dart:io';

import 'scout_tracking_http_client.dart';

/// Data class for completed HTTP request info.
class HttpRequestData {
  final String method;
  final Uri url;
  final int statusCode;
  final int durationMs;
  final int responseSize;
  final String? error;

  HttpRequestData({
    required this.method,
    required this.url,
    required this.statusCode,
    required this.durationMs,
    required this.responseSize,
    this.error,
  });
}

/// HttpOverrides that wraps any existing overrides to inject HTTP tracking.
class ScoutHttpOverrides extends HttpOverrides {
  final HttpOverrides? existingOverrides;
  final String exportEndpoint;
  final List<RegExp>? ignorePatterns;
  final List<String>? firstPartyHosts;
  final void Function(HttpRequestData data) onRequestCompleted;

  ScoutHttpOverrides({
    required this.existingOverrides,
    required this.exportEndpoint,
    required this.onRequestCompleted,
    this.ignorePatterns,
    this.firstPartyHosts,
  });

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = existingOverrides?.createHttpClient(context) ??
        super.createHttpClient(context);
    return ScoutTrackingHttpClient(
      inner: inner,
      exportEndpoint: exportEndpoint,
      ignorePatterns: ignorePatterns,
      firstPartyHosts: firstPartyHosts,
      onRequestCompleted: onRequestCompleted,
    );
  }
}

/// Check whether a URL should be tracked.
bool shouldTrackUrl(
  Uri url, {
  required String exportEndpoint,
  List<RegExp>? ignorePatterns,
}) {
  final urlStr = url.toString();
  if (urlStr.startsWith(exportEndpoint)) return false;
  if (ignorePatterns != null) {
    for (final pattern in ignorePatterns) {
      if (pattern.hasMatch(urlStr)) return false;
    }
  }
  return true;
}

/// Check whether a host is in the first-party list (supports *.example.com wildcards).
bool isFirstPartyHost(String host, List<String>? firstPartyHosts) {
  if (firstPartyHosts == null || firstPartyHosts.isEmpty) return false;
  for (final pattern in firstPartyHosts) {
    if (pattern.startsWith('*.')) {
      final suffix = pattern.substring(1); // ".example.com"
      if (host.endsWith(suffix) || host == pattern.substring(2)) return true;
    } else {
      if (host == pattern) return true;
    }
  }
  return false;
}

/// Generate a W3C traceparent header value.
String generateTraceparent(String traceId, String spanId) {
  return '00-$traceId-$spanId-01';
}
