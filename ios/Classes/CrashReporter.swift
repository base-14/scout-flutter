import Foundation
import KSCrash

/// Native crash reporter for iOS — backed by KSCrash 2.5+.
///
/// On first launch we install KSCrash with all five available monitors
/// (Mach exception, POSIX signal, C++ exception, NSException, main-thread
/// deadlock). When the app crashes, KSCrash writes a JSON report to disk
/// before the OS terminates the process. On the next launch we drain
/// those reports here and convert each one to a flat dict the Dart side
/// can attach to a `native_crash` span — extracting fault registers
/// (FAR / ESR on ARM64), Mach exception code, signal info, the crashed
/// thread's stack, all loaded binary images (for offline symbolication),
/// and a per-thread callstack tree.
///
/// MetricKit complements this: `MetricKitSubscriber` collects crash and
/// hang payloads that the OS delivers asynchronously up to 24h after
/// the fact. Both feed into the same `native_crash` Dart pipeline.
class CrashReporter {
    private static var isInstalled = false

    /// Install KSCrash crash handlers. Idempotent.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let config = KSCrashConfiguration()
        // All available monitors — every crash path the OS can throw at us.
        config.monitors = [
            .machException,
            .signal,
            .cppException,
            .nsException,
            .mainThreadDeadlock,
        ]
        do {
            try KSCrash.shared.install(with: config)
        } catch {
            NSLog("ScoutFlutter: KSCrash install failed: \(error)")
        }
    }

    /// Returns pending crash reports from the previous session as
    /// flat dicts ready for Flutter method-channel handoff. Reports
    /// are deleted from disk after they're returned.
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
            guard let reportDict = store.report(for: reportId.int64Value) as? CrashReportDictionary else {
                continue
            }
            let report = reportDict.value as [String: Any]
            if let parsed = parseReport(report) {
                reports.append(parsed)
            }
        }
        store.deleteAllReports()
        return reports
    }

    // MARK: - Parse

    private static func parseReport(_ report: [String: Any]) -> [String: Any]? {
        var out: [String: Any] = [:]

        // ---- report.* ----
        if let reportInfo = report["report"] as? [String: Any] {
            if let ts = reportInfo["timestamp"] as? String { out["crash_timestamp"] = ts }
            if let id = reportInfo["id"] as? String { out["crash_report_id"] = id }
        }
        if out["crash_timestamp"] == nil {
            out["crash_timestamp"] = ISO8601DateFormatter().string(from: Date())
        }

        // ---- system.* (device / OS / build / arch) ----
        if let system = report["system"] as? [String: Any] {
            if let osName = system["system_name"] as? String { out["crash_os_name"] = osName }
            if let osVersion = system["system_version"] as? String { out["crash_os_version"] = osVersion }
            if let kernel = system["kernel_version"] as? String { out["crash_kernel_version"] = kernel }
            if let model = system["model"] as? String { out["crash_device_model"] = model }
            if let machine = system["machine"] as? String { out["crash_machine"] = machine }
            if let arch = system["cpu_arch"] as? String { out["crash_cpu_arch"] = arch }
            if let buildType = system["build_type"] as? String { out["crash_build_type"] = buildType }
            if let process = system["process_name"] as? String { out["crash_process_name"] = process }
        }

        // ---- crash.error.* ----
        let crash = report["crash"] as? [String: Any]
        let error = crash?["error"] as? [String: Any]

        if let type = error?["type"] as? String { out["crash_type"] = type }

        // Mach exception
        if let mach = error?["mach"] as? [String: Any] {
            if let exceptionName = mach["exception_name"] as? String {
                out["crash_mach_exception"] = exceptionName
                if out["crash_reason"] == nil { out["crash_reason"] = exceptionName }
            }
            if let code = mach["code_name"] as? String {
                out["crash_mach_code"] = code
            } else if let codeInt = mach["code"] as? NSNumber {
                out["crash_mach_code"] = codeInt.stringValue
            }
            if let subcode = mach["subcode"] as? NSNumber {
                out["crash_mach_subcode"] = subcode.stringValue
            }
        }

        // POSIX signal
        if let signal = error?["signal"] as? [String: Any] {
            if let name = signal["name"] as? String {
                out["crash_signal"] = name
                if out["crash_reason"] == nil { out["crash_reason"] = name }
            }
            if let codeName = signal["code_name"] as? String {
                out["crash_signal_code"] = codeName
            }
            if let address = signal["address"] as? NSNumber {
                out["crash_signal_address"] = String(format: "0x%llx", address.uint64Value)
            }
        }

        // NSException
        if let nsex = error?["nsexception"] as? [String: Any] {
            if let name = nsex["name"] as? String { out["crash_nsexception_name"] = name }
            if let reason = nsex["reason"] as? String {
                if out["crash_reason"] == nil { out["crash_reason"] = reason }
            }
        }

        // Generic reason fallback
        if out["crash_reason"] == nil, let reason = error?["reason"] as? String {
            out["crash_reason"] = reason
        }
        if out["crash_reason"] == nil {
            out["crash_reason"] = "Unknown"
        }

        // ---- crashed thread stack + register dump ----
        if let threads = crash?["threads"] as? [[String: Any]] {
            let crashedThread = threads.first(where: { ($0["crashed"] as? Bool) == true }) ?? threads.first
            if let bt = crashedThread?["backtrace"] as? [String: Any],
               let frames = bt["contents"] as? [[String: Any]] {
                out["crash_stack_trace"] = formatStack(frames)
            }
            if let threadName = crashedThread?["name"] as? String,
               !threadName.isEmpty {
                out["crash_thread"] = threadName
            } else if let queueName = crashedThread?["dispatch_queue"] as? String {
                out["crash_thread"] = queueName
            }

            // Register snapshot — FAR / ESR / PC / LR on ARM64.
            if let registers = crashedThread?["registers"] as? [String: Any],
               let regsJson = try? JSONSerialization.data(
                   withJSONObject: registers,
                   options: [.sortedKeys]
               ),
               let regsString = String(data: regsJson, encoding: .utf8) {
                out["crash_registers_json"] = regsString
            }

            // Full per-thread callstack tree for offline symbolication / diff.
            if let allThreadsJson = try? JSONSerialization.data(
                   withJSONObject: threads,
                   options: []
               ),
               let s = String(data: allThreadsJson, encoding: .utf8) {
                // Truncate to avoid OTLP payload bloat.
                out["crash_callstack_tree_json"] = String(s.prefix(32_000))
            }
        }

        // ---- binary images ----
        if let images = report["binary_images"] as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: images, options: []),
           let s = String(data: json, encoding: .utf8) {
            // Cap — full binary list on a large iOS app is ~200KB.
            out["crash_binary_images_json"] = String(s.prefix(16_000))
        }

        // ---- process info ----
        if let process = report["process"] as? [String: Any] {
            if let pid = process["pid"] as? NSNumber { out["crash_pid"] = pid.intValue }
        }

        return out.isEmpty ? nil : out
    }

    private static func formatStack(_ frames: [[String: Any]]) -> String {
        let lines: [String] = frames.prefix(60).map { frame in
            let symbol = frame["symbol_name"] as? String ?? "??"
            let addr = (frame["instruction_addr"] as? NSNumber)?.uint64Value ?? 0
            let obj = frame["object_name"] as? String ?? "??"
            let offset = (frame["symbol_addr"] as? NSNumber)?.uint64Value ?? 0
            let delta = addr >= offset ? addr - offset : 0
            return "\(obj) 0x\(String(addr, radix: 16)) \(symbol) + \(delta)"
        }
        return lines.joined(separator: "\n")
    }
}
