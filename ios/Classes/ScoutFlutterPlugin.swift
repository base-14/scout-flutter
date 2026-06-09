import Flutter
import KSCrash

public class ScoutFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var anrWatchdog: AppHangWatchdog?
    private var uiHangWatchdog: AppHangWatchdog?

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
            let args = call.arguments as? [String: Any]
            let thresholdMs = args?["thresholdMs"] as? Int ?? 5000
            anrWatchdog?.stop()
            anrWatchdog = AppHangWatchdog(
                label: "anr",
                thresholdMs: thresholdMs
            ) { [weak self] durationMs in
                DispatchQueue.main.async {
                    self?.channel.invokeMethod("onAnrDetected", arguments: durationMs)
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
        case "simulateAnr":
            let args = call.arguments as? [String: Any]
            let durationMs = args?["durationMs"] as? Int ?? 6000
            // Block native main thread to trigger the ANR watchdog
            Thread.sleep(forTimeInterval: Double(durationMs) / 1000.0)
            result(nil)
        case "simulateCrash":
            // Real crash so KSCrash actually fires. Dart `exit(0/1)` is a
            // graceful shutdown that no crash reporter intercepts.
            // The dispatch.async hop keeps Flutter's method-channel
            // accounting from screaming about a missing result().
            DispatchQueue.main.async {
                // Null-pointer write — synthesises EXC_BAD_ACCESS / SIGSEGV.
                let ptr: UnsafeMutablePointer<Int32>? = nil
                ptr!.pointee = 0
            }
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
}
