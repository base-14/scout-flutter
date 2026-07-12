import Flutter
import Scout
import ScoutKit

public class ScoutFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel

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
            Scout.startBridge(
                serviceName: serviceName,
                endpoint: endpoint,
                environment: environment,
                headers: headers,
                sessionSampleRate: sampleRate,
                anrThresholdMs: anrMs
            )
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
