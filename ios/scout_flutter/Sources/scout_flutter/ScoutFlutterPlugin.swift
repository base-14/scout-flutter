import Flutter
#if canImport(KSCrash)
import KSCrash
#else
import KSCrashRecording
#endif

public class ScoutFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var anrWatchdog: AppHangWatchdog?
    private var uiHangWatchdog: AppHangWatchdog?
    private var mainThreadPort: thread_t = thread_t(MACH_PORT_NULL)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.base14.scout_flutter",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScoutFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Install crash handlers as early as possible.
        CrashReporter.install()
        // Subscribe to MetricKit so delayed crash/hang payloads queue
        // up in memory until the Dart side drains them.
        ScoutMetricKitSubscriber.shared.start()
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startAnrDetection":
            if mainThreadPort == thread_t(MACH_PORT_NULL) {
                mainThreadPort = ScoutThreadBacktrace.currentPort()
            }
            let args = call.arguments as? [String: Any]
            let thresholdMs = args?["thresholdMs"] as? Int ?? 5000
            anrWatchdog?.stop()
            anrWatchdog = AppHangWatchdog(
                label: "anr",
                thresholdMs: thresholdMs
            ) { [weak self] durationMs in
                guard let self = self else { return }
                let frames = ScoutThreadBacktrace.capture(self.mainThreadPort)
                let mainStack = frames.joined(separator: "\n")
                DispatchQueue.main.async {
                    var payload: [String: Any] = ["duration": durationMs]
                    if !mainStack.isEmpty {
                        payload["main_thread_stack"] = mainStack
                    }
                    self.channel.invokeMethod("onAnrDetected", arguments: payload)
                }
            }
            anrWatchdog?.start()
            result(nil)
        case "stopAnrDetection":
            anrWatchdog?.stop()
            anrWatchdog = nil
            result(nil)
        case "startUiHangDetection":
            // Separate watchdog from ANR — fires at ~250 ms to catch
            // micro-stutters (button tap → 300 ms freeze → recover).
            // KSCrash's mainThreadDeadlock only fires at 5 s; this fills
            // the gap.
            let args = call.arguments as? [String: Any]
            let thresholdMs = args?["thresholdMs"] as? Int ?? 250
            uiHangWatchdog?.stop()
            uiHangWatchdog = AppHangWatchdog(
                label: "ui_hang",
                thresholdMs: thresholdMs,
                pollIntervalMs: max(20, thresholdMs / 4)
            ) { [weak self] durationMs in
                DispatchQueue.main.async {
                    self?.channel.invokeMethod("onUiHangDetected", arguments: durationMs)
                }
            }
            uiHangWatchdog?.start()
            result(nil)
        case "stopUiHangDetection":
            uiHangWatchdog?.stop()
            uiHangWatchdog = nil
            result(nil)
        case "getMemoryUsage":
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let resultCode = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if resultCode == KERN_SUCCESS {
                result(["used": info.resident_size, "max": ProcessInfo.processInfo.physicalMemory])
            } else {
                result(["used": -1, "max": -1])
            }

        case "getCpuUsage":
            var threadList: thread_act_array_t?
            var threadCount: mach_msg_type_number_t = 0
            let threadResult = task_threads(mach_task_self_, &threadList, &threadCount)
            var totalCpu = 0.0
            if threadResult == KERN_SUCCESS, let threads = threadList {
                for i in 0..<Int(threadCount) {
                    var threadInfo = thread_basic_info()
                    var threadInfoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                    let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                            thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                        }
                    }
                    if infoResult == KERN_SUCCESS {
                        let usage = Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                        totalCpu += usage
                    }
                }
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
            }
            result(["cpu_percent": totalCpu])

        case "getNativeCrashReports":
            let reports = CrashReporter.getPendingCrashReports()
            result(reports)

        case "getMetricKitReports":
            let reports = ScoutMetricKitSubscriber.shared.drainPending()
            result(reports)

        case "getTimezone":
            result(TimeZone.current.identifier)

        case "getOsBuild":
            let osVerStr = ProcessInfo.processInfo.operatingSystemVersionString
            if let range = osVerStr.range(of: "Build "),
               let end = osVerStr.range(of: ")", range: range.upperBound..<osVerStr.endIndex) {
                result(String(osVerStr[range.upperBound..<end.lowerBound]))
            } else {
                result("")
            }

        case "getCpuArch":
            #if arch(arm64)
            result("arm64")
            #elseif arch(x86_64)
            result("amd64")
            #elseif arch(arm)
            result("arm32")
            #else
            result("")
            #endif

        case "isDeviceCompromised":
            result(isJailbroken())

        case "setBreadcrumbs":
            let args = call.arguments as? [String: Any]
            let json = (args?["json"] as? String) ?? ""
            var info = KSCrash.shared.userInfo ?? [:]
            if json.isEmpty {
                info.removeValue(forKey: "breadcrumbs")
            } else {
                info["breadcrumbs"] = json
            }
            KSCrash.shared.userInfo = info
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/usr/libexec/ssh-keysign",
            "/usr/libexec/sftp-server",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app"
        ]
        let fm = FileManager.default
        for path in paths {
            if fm.fileExists(atPath: path) { return true }
        }
        if ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil {
            return true
        }
        let probe = "/private/scout_jb_probe.txt"
        do {
            try "probe".write(toFile: probe, atomically: true, encoding: .utf8)
            try? fm.removeItem(atPath: probe)
            return true
        } catch {
            return false
        }
        #endif
    }
}
