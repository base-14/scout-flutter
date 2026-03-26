import Foundation
import KSCrash

/// Native crash reporter for iOS using KSCrash.
///
/// Installs crash handlers on first call to `install()`. On subsequent launches,
/// `getPendingCrashReports()` retrieves reports from the previous session.
class CrashReporter {
    private static var isInstalled = false

    /// Install KSCrash crash handlers. Call once during plugin init.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let config = KSCrashConfiguration()
        config.monitors = [.machException, .signal, .cppException, .nsException]
        do {
            try KSCrash.shared.install(with: config)
        } catch {
            NSLog("ScoutFlutter: KSCrash install failed: \(error)")
        }
    }

    /// Returns pending crash reports from the previous session, then deletes them.
    static func getPendingCrashReports() -> [[String: Any]] {
        let store: CrashReportStore
        do {
            store = try CrashReportStore.defaultStore()
        } catch {
            NSLog("ScoutFlutter: Failed to get crash report store: \(error)")
            return []
        }

        let reportIds = store.reportIDs
        if reportIds.isEmpty { return [] }

        var reports: [[String: Any]] = []

        for reportId in reportIds {
            guard let report = store.report(for: reportId.int64Value) as? [String: Any] else {
                continue
            }

            var parsed: [String: Any] = [:]

            // Extract crash info
            if let crash = report["crash"] as? [String: Any],
               let error = crash["error"] as? [String: Any] {

                if let type = error["type"] as? String {
                    parsed["crash_type"] = type
                }

                if let mach = error["mach"] as? [String: Any],
                   let exceptionName = mach["exception_name"] as? String {
                    parsed["crash_reason"] = exceptionName
                } else if let signal = error["signal"] as? [String: Any],
                          let name = signal["name"] as? String {
                    parsed["crash_reason"] = name
                } else if let nsException = error["nsexception"] as? [String: Any],
                          let reason = nsException["reason"] as? String {
                    parsed["crash_reason"] = reason
                } else if let reason = error["reason"] as? String {
                    parsed["crash_reason"] = reason
                } else {
                    parsed["crash_reason"] = "Unknown"
                }

                // Stack trace from crashed thread
                if let threads = crash["threads"] as? [[String: Any]] {
                    let crashedThread = threads.first(where: { ($0["crashed"] as? Bool) == true }) ?? threads.first
                    if let bt = crashedThread?["backtrace"] as? [String: Any],
                       let frames = bt["contents"] as? [[String: Any]] {
                        let trace = frames.prefix(30).map { frame in
                            let symbol = frame["symbol_name"] as? String ?? "??"
                            let addr = frame["instruction_addr"] as? UInt64 ?? 0
                            let obj = frame["object_name"] as? String ?? "??"
                            return "\(obj) 0x\(String(addr, radix: 16)) \(symbol)"
                        }.joined(separator: "\n")
                        parsed["crash_stack_trace"] = trace
                    }

                    if let threadName = crashedThread?["name"] as? String {
                        parsed["crash_thread_name"] = threadName
                    }
                }
            }

            // Timestamp
            if let reportInfo = report["report"] as? [String: Any],
               let timestamp = reportInfo["timestamp"] as? String {
                parsed["crash_timestamp"] = timestamp
            } else {
                parsed["crash_timestamp"] = ISO8601DateFormatter().string(from: Date())
            }

            if !parsed.isEmpty {
                reports.append(parsed)
            }
        }

        store.deleteAllReports()
        return reports
    }
}
