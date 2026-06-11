import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// MetricKit subscriber — captures the delayed crash + hang payloads
/// that the OS delivers asynchronously, up to 24h after the event.
/// Complements KSCrash (which catches the moment of crash in-process)
/// with Apple's curated post-mortem data: signal info pulled by the
/// kernel, register dumps, and per-thread call stacks that survived
/// the crash even when KSCrash couldn't write to disk.
///
/// Available on iOS 14+. On earlier versions this class is a no-op
/// shell so the rest of the SDK doesn't need to feature-gate.
@objc class ScoutMetricKitSubscriber: NSObject {
    static let shared = ScoutMetricKitSubscriber()
    private var pending: [[String: Any]] = []
    private let lock = NSLock()

    /// Subscribe to MetricKit if available. Idempotent.
    @objc func start() {
        if #available(iOS 14.0, *) {
            #if canImport(MetricKit)
            MXMetricManager.shared.add(self)
            #endif
        }
    }

    /// Pull and clear any payloads delivered since the last drain.
    /// Each returned dict is shaped like a KSCrash-parsed report so the
    /// Dart side can treat both pipelines identically.
    @objc func drainPending() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending = []
        return out
    }
}

#if canImport(MetricKit)
@available(iOS 14.0, *)
extension ScoutMetricKitSubscriber: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics — MXMetricPayload is for non-fatal vitals.
        // No-op here; the SDK already covers performance signals
        // (frame timing, memory polling) via Flutter-side collectors.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock()
        defer { lock.unlock() }
        let now = ISO8601DateFormatter().string(from: Date())
        for payload in payloads {
            payload.crashDiagnostics?.forEach { diag in
                pending.append(parseCrash(diag, fallbackTimestamp: now))
            }
            payload.hangDiagnostics?.forEach { diag in
                pending.append(parseHang(diag, fallbackTimestamp: now))
            }
        }
    }

    private func parseCrash(
        _ diag: MXCrashDiagnostic,
        fallbackTimestamp: String
    ) -> [String: Any] {
        var out: [String: Any] = [
            "crash_type": "metrickit_crash",
            "crash_timestamp": fallbackTimestamp,
        ]
        out["crash_reason"] = diag.terminationReason ?? "MetricKit crash"
        if let signal = diag.signal {
            out["crash_signal"] = signal.stringValue
        }
        if let code = diag.exceptionCode {
            out["crash_mach_code"] = code.stringValue
        }
        if let type = diag.exceptionType {
            out["crash_mach_exception"] = type.stringValue
        }
        out["crash_stack_trace"] = diag.callStackTree.jsonRepresentation()
            .base64EncodedString()
        if let app = diag.applicationVersion as String? {
            out["crash_app_version"] = app
        }
        out["crash_os_version"] = diag.metaData.osVersion
        return out
    }

    private func parseHang(
        _ diag: MXHangDiagnostic,
        fallbackTimestamp: String
    ) -> [String: Any] {
        var out: [String: Any] = [
            "crash_type": "metrickit_hang",
            "crash_timestamp": fallbackTimestamp,
        ]
        out["crash_reason"] = "App hang for \(diag.hangDuration.value) \(diag.hangDuration.unit.symbol)"
        out["crash_stack_trace"] = diag.callStackTree.jsonRepresentation()
            .base64EncodedString()
        if let app = diag.applicationVersion as String? {
            out["crash_app_version"] = app
        }
        out["crash_os_version"] = diag.metaData.osVersion
        return out
    }
}
#endif
