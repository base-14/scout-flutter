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
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
