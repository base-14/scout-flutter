import Flutter
import Scout
import ScoutKit

public class ScoutFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    /// Set once `Scout.startBridge` ran; before that the engine has no
    /// session context to report.
    private var engineStarted = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.base14.scout_flutter",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScoutFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initNativeDelegate":
            let args = call.arguments as? [String: Any]
            let serviceName = (args?["serviceName"] as? String) ?? ""
            let endpoint = (args?["endpoint"] as? String) ?? ""
            let environment = args?["environment"] as? String
            let headers = (args?["headers"] as? [String: String]) ?? [:]
            let sampleRate = (args?["sessionSampleRate"] as? Double) ?? 1.0
            if serviceName.isEmpty || endpoint.isEmpty {
                result(false)
                return
            }
            let anrMs = (args?["anrThresholdMs"] as? Double) ?? 3000
            let flutterVersion = args?["scoutFlutterVersion"] as? String
            Scout.startBridge(
                serviceName: serviceName,
                endpoint: endpoint,
                environment: environment,
                headers: headers,
                sessionSampleRate: sampleRate,
                anrThresholdMs: anrMs,
                resourceAttributes: flutterVersion.map { ["scout.flutter.version": $0] } ?? [:],
                exportIntervalSeconds: (args?["exportIntervalSeconds"] as? Int) ?? 30,
                maxExportBatchSize: (args?["maxExportBatchSize"] as? Int) ?? 512,
                maxQueueSize: (args?["maxQueueSize"] as? Int) ?? 2048,
                maxRetries: (args?["maxRetries"] as? Int) ?? 0,
                vitalsCollectionIntervalSeconds: (args?["vitalsCollectionIntervalSeconds"] as? Int) ?? 60,
                offlineBufferEnabled: (args?["offlineBufferEnabled"] as? Bool) ?? false,
                enableMemoryMetrics: (args?["enableMemoryMetrics"] as? Bool) ?? false,
                enableCpuMetrics: (args?["enableCpuMetrics"] as? Bool) ?? false,
                enableFrameMetrics: (args?["enableFrameMetrics"] as? Bool) ?? false,
                metricExportIntervalSeconds: (args?["metricExportIntervalSeconds"] as? Int) ?? -1,
                firstPartyHosts: (args?["firstPartyHosts"] as? [String]) ?? [],
                maxOfflineStorageMb: (args?["maxOfflineStorageMb"] as? Int) ?? 5,
                debugLogging: (args?["debugLogging"] as? Bool) ?? false
            )
            engineStarted = true
            result(true)

        case "ingestSpans":
            let json = ((call.arguments as? [String: Any])?["json"] as? String) ?? ""
            ScoutEngine.shared.ingestForwardedSpans(payloadJson: json)
            result(nil)

        case "ingestLogs":
            let json = ((call.arguments as? [String: Any])?["json"] as? String) ?? ""
            ScoutEngine.shared.ingestForwardedLogs(payloadJson: json)
            result(nil)

        case "ingestMetrics":
            let json = ((call.arguments as? [String: Any])?["json"] as? String) ?? ""
            ScoutEngine.shared.ingestForwardedMetrics(payloadJson: json)
            result(nil)

        case "pushBreadcrumbs":
            let json = ((call.arguments as? [String: Any])?["json"] as? String) ?? ""
            ScoutEngine.shared.pushBreadcrumbs(payloadJson: json)
            result(nil)

        case "setBreadcrumbs":
            let json = ((call.arguments as? [String: Any])?["json"] as? String) ?? ""
            ScoutEngine.shared.setBreadcrumbs(payloadJson: json)
            result(nil)

        case "readOwner":
            let ctx = ScoutEngine.shared.bridgeContext()
            result(ctx.isEmpty ? nil : ctx)

        case "setScreen":
            let name = ((call.arguments as? [String: Any])?["name"] as? String) ?? ""
            ScoutEngine.shared.setScreen(name: name)
            result(nil)

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

        case "getSessionIdentity":
            // Nil until the engine runs — the Dart side then keeps its own
            // ids, which is correct because nothing native is exporting.
            // The iOS engine exposes its SessionContext only as the JSON the
            // bridge codec produces (`{"sessionId":…,"anonymousId":…,…}`).
            if engineStarted,
               let data = ScoutEngine.shared.bridgeContext().data(using: .utf8),
               let ctx = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let sessionId = ctx["sessionId"] as? String, !sessionId.isEmpty {
                result([
                    "sessionId": sessionId,
                    "anonymousId": (ctx["anonymousId"] as? String) ?? "",
                ])
            } else {
                result(nil)
            }

        case "getProcessStartTimeMillis":
            if let ms = processStartTimeMillis() {
                result(NSNumber(value: ms))
            } else {
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Epoch ms at which the kernel forked this process (kp_proc.p_starttime),
    /// or nil when it cannot serve as a user-perceived launch anchor. iOS 15+
    /// may prewarm the process minutes before the user taps the icon; such
    /// launches carry ActivePrewarm=1 in the environment, and we opt out so the
    /// Dart side falls back to its SDK-init stopwatch instead of over-reporting.
    private func processStartTimeMillis() -> Int64? {
        if ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
        }
        guard rc == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        let ms = Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
        return ms > 0 ? ms : nil
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
