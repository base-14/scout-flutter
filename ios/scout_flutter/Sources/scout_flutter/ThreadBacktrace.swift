import Foundation
import Darwin

enum ScoutThreadBacktrace {

    private static let addressMask: UInt = 0x0000_FFFF_FFFF_FFFF

    static func currentPort() -> thread_t {
        return mach_thread_self()
    }

    static func capture(_ thread: thread_t, maxFrames: Int = 64) -> [String] {
        if thread == thread_t(MACH_PORT_NULL) { return [] }
        if thread_suspend(thread) != KERN_SUCCESS { return [] }
        defer { thread_resume(thread) }

        var pc: UInt = 0
        var fp: UInt = 0

        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        if kr != KERN_SUCCESS { return [] }
        pc = UInt(state.__pc) & addressMask
        fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &count)
            }
        }
        if kr != KERN_SUCCESS { return [] }
        pc = UInt(state.__rip) & addressMask
        fp = UInt(state.__rbp)
        #else
        return []
        #endif

        var frames: [String] = []
        if pc != 0 { frames.append(symbolicate(pc)) }

        let pointerSize = UInt(MemoryLayout<UInt>.size)
        var currentFp = fp
        var previousFp: UInt = 0
        var depth = 0
        while currentFp != 0 && depth < maxFrames {
            if currentFp <= previousFp { break }
            if currentFp % 16 != 0 { break }
            guard let fpPtr = UnsafePointer<UInt>(bitPattern: currentFp),
                  let lrPtr = UnsafePointer<UInt>(bitPattern: currentFp + pointerSize)
            else { break }
            let savedFp = fpPtr.pointee
            let savedLr = lrPtr.pointee & addressMask
            if savedLr == 0 { break }
            frames.append(symbolicate(savedLr))
            previousFp = currentFp
            currentFp = savedFp
            depth += 1
        }
        return frames
    }

    private static func symbolicate(_ address: UInt) -> String {
        let hex = "0x" + String(address, radix: 16)
        var info = dl_info()
        if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
           let namePtr = info.dli_sname {
            let symbol = String(cString: namePtr)
            let base = UInt(bitPattern: info.dli_saddr)
            let offset = address >= base ? address - base : 0
            return "\(hex) \(symbol) + \(offset)"
        }
        return hex
    }
}
