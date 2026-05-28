import Foundation
import KSCrash
import UIKit

class CrashReporter {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let config = KSCrashConfiguration()
        config.monitors = [
            .machException,
            .signal,
            .cppException,
            .nsException,
            .mainThreadDeadlock,
            .userReported,
            .system,
            .applicationState,
        ]
        do {
            try KSCrash.shared.install(with: config)
        } catch {
            NSLog("ScoutFlutter: KSCrash install failed: \(error)")
        }
    }

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
            if let type = reportInfo["type"] as? String { out["crash_report_type"] = type }
            if let version = reportInfo["version"] as? String { out["crash_report_version"] = version }
        }
        if out["crash_timestamp"] == nil {
            out["crash_timestamp"] = ISO8601DateFormatter().string(from: Date())
        }

        // ---- system.* (device / OS / build / arch / memory / app metadata) ----
        if let system = report["system"] as? [String: Any] {
            put(&out, "crash_os_name",         system["system_name"])
            put(&out, "crash_os_version",      system["system_version"])
            put(&out, "crash_os_build",        system["os_version"])
            put(&out, "crash_kernel_version",  system["kernel_version"])
            put(&out, "crash_boot_time",       system["boot_time"])
            put(&out, "crash_app_start_time",  system["app_start_time"])
            put(&out, "crash_time_zone",       system["time_zone"])

            put(&out, "crash_device_model",    system["model"])
            put(&out, "crash_machine",         system["machine"])
            put(&out, "crash_cpu_arch",        system["cpu_arch"])
            put(&out, "crash_cpu_type",        system["cpu_type"])
            put(&out, "crash_cpu_subtype",     system["cpu_subtype"])
            put(&out, "crash_binary_cpu_type",    system["binary_cpu_type"])
            put(&out, "crash_binary_cpu_subtype", system["binary_cpu_subtype"])

            put(&out, "crash_app_name",        system["CFBundleName"])
            put(&out, "crash_app_executable",  system["CFBundleExecutable"])
            put(&out, "crash_bundle_id",       system["CFBundleIdentifier"])
            put(&out, "crash_app_version",     system["CFBundleShortVersionString"])
            put(&out, "crash_bundle_version",  system["CFBundleVersion"])
            put(&out, "crash_executable_path", system["CFBundleExecutablePath"])
            put(&out, "crash_app_id",          system["CFBundleIdentifier"])
            put(&out, "crash_build_type",      system["build_type"])
            put(&out, "crash_device_app_hash", system["device_app_hash"])
            put(&out, "crash_app_uuid",        system["app_uuid"])

            put(&out, "crash_process_name",    system["process_name"])
            put(&out, "crash_pid",             system["process_id"])
            put(&out, "crash_parent_pid",      system["parent_process_id"])

            if let memory = system["memory"] as? [String: Any] {
                put(&out, "crash_memory_size_bytes",   memory["size"])
                put(&out, "crash_memory_free_bytes",   memory["free"])
                put(&out, "crash_memory_usable_bytes", memory["usable"])
            }
            if let appMem = system["app_memory"] as? [String: Any] {
                put(&out, "crash_memory_footprint",     appMem["memory_footprint"])
                put(&out, "crash_memory_remaining",     appMem["memory_remaining"])
                put(&out, "crash_memory_pressure",      appMem["memory_pressure"])
                put(&out, "crash_memory_level",         appMem["memory_level"])
                put(&out, "crash_memory_limit",         appMem["memory_limit"])
                put(&out, "crash_app_transition_state", appMem["app_transition_state"])
            }
            put(&out, "crash_storage_size_bytes", system["storage"])

            if let jailbroken = system["jailbroken"] as? Bool {
                out["crash_jailbroken"] = jailbroken
            }
            put(&out, "crash_last_dealloced_nsexception", system["last_dealloced_nsexception"])

            if let stats = system["application_stats"] as? [String: Any] {
                put(&out, "crash_app_active_time_secs",                  stats["active_time_since_launch"])
                put(&out, "crash_app_background_time_secs",              stats["background_time_since_launch"])
                put(&out, "crash_app_active_time_since_last_crash_secs", stats["active_time_since_last_crash"])
                put(&out, "crash_app_background_time_since_last_crash_secs", stats["background_time_since_last_crash"])
                put(&out, "crash_app_launches_since_last_crash",         stats["launches_since_last_crash"])
                put(&out, "crash_app_sessions_since_last_crash",         stats["sessions_since_last_crash"])
                put(&out, "crash_app_sessions_since_launch",             stats["sessions_since_launch"])
                if let fg = stats["application_in_foreground"] as? Bool {
                    out["crash_app_in_foreground"] = fg
                }
                if let active = stats["application_active"] as? Bool {
                    out["crash_app_active"] = active
                }
            }
        }

        addDrainTimeContext(&out)
        addProcessSysctlContext(&out)

        // ---- crash.error.* ----
        let crash = report["crash"] as? [String: Any]
        let error = crash?["error"] as? [String: Any]

        put(&out, "crash_type",      error?["type"])
        put(&out, "crash_diagnosis", crash?["diagnosis"])

        if let termination = error?["termination"] as? [String: Any] ?? crash?["termination"] as? [String: Any] {
            put(&out, "crash_termination_flags",     termination["flags"])
            put(&out, "crash_termination_code",      termination["code"])
            put(&out, "crash_termination_namespace", termination["namespace"])
            put(&out, "crash_termination_indicator", termination["indicator"])
            put(&out, "crash_termination_by_proc",   termination["byProc"])
            put(&out, "crash_termination_by_pid",    termination["byPid"])
        }

        if let mach = error?["mach"] as? [String: Any] {
            if let exceptionName = mach["exception_name"] as? String {
                out["crash_mach_exception"] = exceptionName
                if out["crash_reason"] == nil { out["crash_reason"] = exceptionName }
            }
            put(&out, "crash_mach_code",         mach["code"])
            put(&out, "crash_mach_code_name",    mach["code_name"])
            put(&out, "crash_mach_subcode",      mach["subcode"])
            put(&out, "crash_mach_exception_code", mach["exception"])
        }

        if let signal = error?["signal"] as? [String: Any] {
            if let name = signal["name"] as? String {
                out["crash_signal"] = name
                if out["crash_reason"] == nil { out["crash_reason"] = name }
            }
            put(&out, "crash_signal_code",      signal["code"])
            put(&out, "crash_signal_code_name", signal["code_name"])
            if let address = signal["address"] as? NSNumber {
                out["crash_signal_address"] = String(format: "0x%llx", address.uint64Value)
            }
            put(&out, "crash_signal_number", signal["signal"])
        }

        // NSException
        if let nsex = error?["nsexception"] as? [String: Any] {
            put(&out, "crash_nsexception_name",   nsex["name"])
            put(&out, "crash_nsexception_userinfo", nsex["userInfo"])
            if let reason = nsex["reason"] as? String,
               out["crash_reason"] == nil {
                out["crash_reason"] = reason
            }
        }

        // C++ exception
        if let cppex = error?["cpp_exception"] as? [String: Any] {
            put(&out, "crash_cpp_exception_name", cppex["name"])
        }

        // Address / instruction info
        put(&out, "crash_fault_address",  error?["address"])
        put(&out, "crash_crashing_thread_index", crash?["crashed_thread"])

        // Generic reason fallback
        if out["crash_reason"] == nil, let reason = error?["reason"] as? String {
            out["crash_reason"] = reason
        }
        if out["crash_reason"] == nil {
            out["crash_reason"] = "Unknown"
        }

        // ---- threads ----
        if let threads = crash?["threads"] as? [[String: Any]] {
            out["crash_thread_count"] = threads.count

            let crashedThread = threads.first(where: { ($0["crashed"] as? Bool) == true }) ?? threads.first

            if let threadName = crashedThread?["name"] as? String, !threadName.isEmpty {
                out["crash_thread_name"] = threadName
                out["crash_thread"] = threadName
            } else if let queueName = crashedThread?["dispatch_queue"] as? String {
                out["crash_thread"] = queueName
            }
            put(&out, "crash_queue",         crashedThread?["dispatch_queue"])
            put(&out, "crash_queue_name",    crashedThread?["queue_name"])
            put(&out, "crash_thread_index",  crashedThread?["index"])
            put(&out, "crash_thread_id",     crashedThread?["thread_id"])
            put(&out, "crash_thread_current", crashedThread?["current_thread"])

            // Crashed-thread flat formatted stack — for the simple "Stack Trace" panel
            if let bt = crashedThread?["backtrace"] as? [String: Any],
               let frames = bt["contents"] as? [[String: Any]] {
                out["crash_stack_trace"] = formatStack(frames)
            }

            // Crashed-thread registers (FAR / ESR / PC / LR on ARM64)
            if let registers = crashedThread?["registers"] as? [String: Any],
               let regsJson = try? JSONSerialization.data(withJSONObject: registers, options: [.sortedKeys]),
               let regsString = String(data: regsJson, encoding: .utf8) {
                out["crash_registers_json"] = regsString

                // Surface FAR/ESR as flat attrs for quick filtering
                if let basic = registers["basic"] as? [String: Any] {
                    if let far = basic["far"] as? NSNumber {
                        out["crash_fault_address_register"] = String(format: "0x%llx", far.uint64Value)
                    }
                    if let esr = basic["esr"] as? NSNumber {
                        out["crash_exception_syndrome_register"] = String(format: "0x%llx", esr.uint64Value)
                    }
                }
                if let exception = registers["exception"] as? [String: Any],
                   let exc = exception["exception"] as? NSNumber {
                    out["crash_exception_register"] = String(format: "0x%llx", exc.uint64Value)
                }
            }

            // Full per-thread callstack tree (all threads, all frames, all registers)
            if let allThreadsJson = try? JSONSerialization.data(withJSONObject: threads, options: []),
               let s = String(data: allThreadsJson, encoding: .utf8) {
                out["crash_callstack_tree_json"] = s
            }
        }

        // ---- binary images (for symbolication) ----
        if let images = report["binary_images"] as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: images, options: []),
           let s = String(data: json, encoding: .utf8) {
            out["crash_binary_images_json"] = s
            out["crash_binary_images_count"] = images.count
        }

        // ---- process info (alternate source) ----
        if let process = report["process"] as? [String: Any] {
            if out["crash_pid"] == nil, let pid = process["pid"] as? NSNumber {
                out["crash_pid"] = pid.intValue
            }
            if out["crash_process_name"] == nil, let name = process["name"] as? String {
                out["crash_process_name"] = name
            }
        }

        // ---- user data / breadcrumbs forwarded from app code ----
        if let userInfo = report["user"] as? [String: Any],
           let userJson = try? JSONSerialization.data(withJSONObject: userInfo, options: []),
           let s = String(data: userJson, encoding: .utf8) {
            out["crash_user_info_json"] = s
        }

        return out.isEmpty ? nil : out
    }

    private static func put(_ dict: inout [String: Any], _ key: String, _ value: Any?) {
        guard let v = value else { return }
        if let s = v as? String, s.isEmpty { return }
        dict[key] = v
    }

    private static func addProcessSysctlContext(_ out: inout [String: Any]) {
        var translated: Int32 = 0
        var tsize = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &tsize, nil, 0) == 0 {
            out["crash_translated"] = translated == 1
        }

        let pid = getpid()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 && size > 0 {
            var buf = [UInt8](repeating: 0, count: size)
            if sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0 {
                let ppid = buf.withUnsafeBytes { raw -> Int32 in
                    let kp = raw.bindMemory(to: kinfo_proc.self).baseAddress!
                    return kp.pointee.kp_eproc.e_ppid
                }
                if out["crash_parent_pid"] == nil {
                    out["crash_parent_pid"] = Int(ppid)
                }
                var pmib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ppid]
                var psize = 0
                if sysctl(&pmib, u_int(pmib.count), nil, &psize, nil, 0) == 0 && psize > 0 {
                    var pbuf = [UInt8](repeating: 0, count: psize)
                    if sysctl(&pmib, u_int(pmib.count), &pbuf, &psize, nil, 0) == 0 {
                        let name = pbuf.withUnsafeBytes { raw -> String in
                            let kp = raw.bindMemory(to: kinfo_proc.self).baseAddress!
                            return withUnsafePointer(to: kp.pointee.kp_proc.p_comm) {
                                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                                    String(cString: $0)
                                }
                            }
                        }
                        if !name.isEmpty {
                            out["crash_parent_proc_name"] = name
                        }
                    }
                }
            }
        }
    }

    private static func addDrainTimeContext(_ out: inout [String: Any]) {
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            out["crash_idfv"] = idfv
        }
        out["crash_uid"] = Int(getuid())
        out["crash_gid"] = Int(getgid())

        var bootTime = timeval()
        var btSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bootTime, &btSize, nil, 0) == 0 {
            let bootDate = Date(timeIntervalSince1970: Double(bootTime.tv_sec))
            out["crash_system_boot_time_iso"] = ISO8601DateFormatter().string(from: bootDate)
            out["crash_time_since_boot_secs"] = Date().timeIntervalSince(bootDate)
        }

        out["crash_drain_uptime_secs"] = ProcessInfo.processInfo.systemUptime
        out["crash_drain_process_start_time"] = ISO8601DateFormatter().string(from: Date())

        let appState = UIApplication.shared.applicationState
        switch appState {
        case .active:     out["crash_drain_app_state"] = "active"
        case .inactive:   out["crash_drain_app_state"] = "inactive"
        case .background: out["crash_drain_app_state"] = "background"
        @unknown default: out["crash_drain_app_state"] = "unknown"
        }

        if let infoDict = Bundle.main.infoDictionary {
            if let v = infoDict["CFBundleShortVersionString"] as? String, out["crash_app_version"] == nil {
                out["crash_app_version"] = v
            }
            if let v = infoDict["CFBundleVersion"] as? String, out["crash_bundle_version"] == nil {
                out["crash_bundle_version"] = v
            }
            if let v = infoDict["CFBundleIdentifier"] as? String, out["crash_bundle_id"] == nil {
                out["crash_bundle_id"] = v
            }
        }

        #if targetEnvironment(simulator)
            out["crash_environment"] = "simulator"
        #else
            out["crash_environment"] = "device"
        #endif

        #if DEBUG
            out["crash_build_configuration"] = "debug"
        #else
            out["crash_build_configuration"] = "release"
        #endif
    }

    private static func formatStack(_ frames: [[String: Any]]) -> String {
        let lines: [String] = frames.map { frame in
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
