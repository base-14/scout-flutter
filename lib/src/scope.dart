/// The single OpenTelemetry InstrumentationScope used for every span, metric,
/// and log emitted by this SDK.
///
/// This is a STRICT invariant: nothing in this package may pass any other
/// name as the scope of a tracer, meter, or logger. A guard test
/// (`test/scope_contract_test.dart`) walks the source tree on every CI run
/// and fails the build if a stray name slips in. Backends rely on the scope
/// name to identify telemetry as Scout-originated.
library;

const String kScopeName = 'base14.scout.flutter';
const String kScopeVersion = '0.1.5';
