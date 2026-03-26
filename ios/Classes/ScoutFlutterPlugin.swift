import Flutter

public class ScoutFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var hangWatchdog: AppHangWatchdog?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.base14.scout_flutter",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScoutFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Install crash handlers as early as possible.
        CrashReporter.install()
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
            hangWatchdog?.stop()
            hangWatchdog = AppHangWatchdog(thresholdMs: thresholdMs) { [weak self] durationMs in
                DispatchQueue.main.async {
                    self?.channel.invokeMethod("onAnrDetected", arguments: durationMs)
                }
            }
            hangWatchdog?.start()
            result(nil)
        case "stopAnrDetection":
            hangWatchdog?.stop()
            hangWatchdog = nil
            result(nil)
        case "simulateAnr":
            let args = call.arguments as? [String: Any]
            let durationMs = args?["durationMs"] as? Int ?? 6000
            // Block native main thread to trigger the ANR watchdog
            Thread.sleep(forTimeInterval: Double(durationMs) / 1000.0)
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
                    var threadInfoCount = mach_msg_type_number_t(THREAD_BASIC_INFO_COUNT)
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

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
