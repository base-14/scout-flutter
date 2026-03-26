import 'package:flutter_test/flutter_test.dart';
import 'package:scout_flutter/src/scout_dio_interceptor.dart';
import 'package:dio/dio.dart';

void main() {
  group('ScoutDioInterceptor', () {
    test('can be instantiated', () {
      final interceptor = ScoutDioInterceptor(onRequestCompleted: (data) {});
      expect(interceptor, isNotNull);
    });

    test('stamps start time in request extras', () {
      final interceptor = ScoutDioInterceptor(onRequestCompleted: (data) {});
      final options = RequestOptions(path: '/test');
      final handler = _MockRequestHandler();
      interceptor.onRequest(options, handler);
      expect(options.extra.containsKey('_scout_start_time'), isTrue);
      expect(handler.nexted, isTrue);
    });

    test('injects traceparent for first-party hosts', () {
      final interceptor = ScoutDioInterceptor(
        firstPartyHosts: ['api.example.com'],
        onRequestCompleted: (data) {},
      );
      final options = RequestOptions(
        baseUrl: 'https://api.example.com',
        path: '/test',
      );
      final handler = _MockRequestHandler();
      interceptor.onRequest(options, handler);
      expect(options.headers['traceparent'], isNotNull);
      expect(
        options.headers['traceparent'],
        matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')),
      );
    });

    test('does not inject traceparent for non-first-party hosts', () {
      final interceptor = ScoutDioInterceptor(
        firstPartyHosts: ['api.example.com'],
        onRequestCompleted: (data) {},
      );
      final options = RequestOptions(
        baseUrl: 'https://other.com',
        path: '/test',
      );
      final handler = _MockRequestHandler();
      interceptor.onRequest(options, handler);
      expect(options.headers.containsKey('traceparent'), isFalse);
    });
  });
}

class _MockRequestHandler extends RequestInterceptorHandler {
  bool nexted = false;
  @override
  void next(RequestOptions requestOptions) {
    nexted = true;
  }
}
