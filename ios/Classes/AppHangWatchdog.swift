import Foundation

class AppHangWatchdog {
    private let thresholdMs: Int
    private let onHangDetected: (Int) -> Void
    private var watchdogQueue: DispatchQueue?
    private var running = false

    init(thresholdMs: Int, onHangDetected: @escaping (Int) -> Void) {
        self.thresholdMs = thresholdMs
        self.onHangDetected = onHangDetected
    }

    func start() {
        running = true
        watchdogQueue = DispatchQueue(label: "com.base14.scout_flutter.anr_watchdog")
        watchdogQueue?.async { [weak self] in
            self?.watchdogLoop()
        }
    }

    func stop() {
        running = false
        watchdogQueue = nil
    }

    deinit {
        stop()
    }

    private func watchdogLoop() {
        while running {
            var responded = false

            DispatchQueue.main.async {
                responded = true
            }

            Thread.sleep(forTimeInterval: Double(thresholdMs) / 1000.0)

            if !responded && running {
                onHangDetected(thresholdMs)
            }
        }
    }
}
