import Foundation
import Darwin

/// Main-thread hang detector.
///
/// Posts a heartbeat block to the main runloop every `pollIntervalMs`.
/// When the watchdog thread sees the heartbeat hasn't advanced in
/// `thresholdMs`, it fires `onHangDetected(elapsedMs)` once — and stays
/// quiet until the main thread recovers, so a single long hang produces
/// one event, not a flood.
///
/// Use one instance per threshold tier:
/// - 250 ms → `ui_hang` span (micro-stutter / jank, recovers quickly)
/// - 5000 ms → `anr` span (full freeze; may not recover before SIGKILL,
///   which is why we fire on threshold cross rather than on recovery)
///
/// Runs on a `.userInitiated` queue so the watchdog itself isn't starved
/// by the app's own background work.
final class AppHangWatchdog {
    private let thresholdMs: Int
    private let pollIntervalMs: Int
    private let onHangDetected: (Int) -> Void
    private let queue: DispatchQueue

    // Heartbeat ns timestamp. Single-producer (main thread) /
    // single-consumer (watchdog thread) of a 64-bit aligned value on
    // 64-bit Darwin — atomic without explicit barriers.
    private var lastHeartbeatNs: UInt64 = 0
    private var running = false
    private var inHang = false

    init(label: String,
         thresholdMs: Int,
         pollIntervalMs: Int = 50,
         onHangDetected: @escaping (Int) -> Void) {
        self.thresholdMs = thresholdMs
        self.pollIntervalMs = max(10, min(pollIntervalMs, thresholdMs))
        self.onHangDetected = onHangDetected
        self.queue = DispatchQueue(
            label: "com.base14.scout_flutter.watchdog.\(label)",
            qos: .userInitiated
        )
    }

    func start() {
        lastHeartbeatNs = Self.nowNs()
        running = true
        queue.async { [weak self] in self?.loop() }
    }

    func stop() { running = false }

    deinit { stop() }

    private func loop() {
        while running {
            // Post the heartbeat — fires after any blocking main-thread
            // work clears. If main is blocked, `lastHeartbeatNs` simply
            // doesn't advance and the elapsed-since-heartbeat below
            // grows until threshold is crossed.
            DispatchQueue.main.async { [weak self] in
                self?.lastHeartbeatNs = Self.nowNs()
            }
            Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
            guard running else { return }

            let elapsedMs = Int((Self.nowNs() &- lastHeartbeatNs) / 1_000_000)

            if elapsedMs >= thresholdMs {
                if !inHang {
                    inHang = true
                    // Fire immediately at threshold cross. This preserves
                    // ANR delivery even when the main thread never
                    // recovers (OS SIGKILL terminates the process before
                    // a recovery-based fire would ever run).
                    onHangDetected(elapsedMs)
                }
            } else if inHang {
                // Main thread is healthy again — re-arm.
                inHang = false
            }
        }
    }

    private static func nowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}
