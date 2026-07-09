// ignore_for_file: implementation_imports
import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/src/metrics/export/otlp/metric_transformer.dart';
import 'package:dartastic_opentelemetry/proto/common/v1/common.pb.dart'
    as common_pb;
import 'package:dartastic_opentelemetry/proto/metrics/v1/metrics.pb.dart'
    as metrics_pb;

import 'scout_platform_channel.dart';

class BridgeMetricExporter implements MetricExporter {
  final String scopeName;
  bool _shutdown = false;

  BridgeMetricExporter(this.scopeName);

  @override
  Future<bool> export(MetricData data) async {
    if (_shutdown || data.metrics.isEmpty) return true;
    final out = <Map<String, Object?>>[];
    for (final metric in data.metrics) {
      final metrics_pb.Metric pb;
      try {
        pb = MetricTransformer.transformMetric(metric);
      } catch (_) {
        continue;
      }
      final Iterable<metrics_pb.NumberDataPoint> points =
          pb.hasGauge()
              ? pb.gauge.dataPoints
              : pb.hasSum()
              ? pb.sum.dataPoints
              : const <metrics_pb.NumberDataPoint>[];
      for (final dp in points) {
        final value = dp.hasAsDouble() ? dp.asDouble : dp.asInt.toDouble();
        final attrs = <String, String>{};
        for (final kv in dp.attributes) {
          attrs[kv.key] = _attrValue(kv.value);
        }
        out.add({
          'scope': scopeName,
          'name': pb.name,
          'value': value,
          'unit': pb.unit,
          'timestamp_unix_nano': dp.timeUnixNano.toString(),
          'attributes': attrs,
        });
      }
    }
    if (out.isNotEmpty) {
      await ScoutPlatformChannel.ingestMetrics(jsonEncode({'metrics': out}));
    }
    return true;
  }

  String _attrValue(common_pb.AnyValue v) {
    if (v.hasStringValue()) return v.stringValue;
    if (v.hasIntValue()) return v.intValue.toString();
    if (v.hasDoubleValue()) return v.doubleValue.toString();
    if (v.hasBoolValue()) return v.boolValue.toString();
    return '';
  }

  @override
  Future<bool> forceFlush() async => true;

  @override
  Future<bool> shutdown() async {
    _shutdown = true;
    return true;
  }
}
