import Foundation

/// Read the resident set size of the current task. Lets the spike print
/// "RSS x.x MB" on-keyboard so we can eyeball memory usage during dictation
/// without needing Instruments attached. Returns nil if the kernel call
/// fails (it shouldn't — `task_info` on `mach_task_self_` is in-process).
enum MemoryProbe {
    static func residentMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPtr,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
}
