import Darwin

/// Utility to read the current process's resident memory footprint.
enum MemoryUtils {
    /// Returns resident memory in megabytes.
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }

    /// Human-readable string: "2.1 GB" or "48 MB".
    static func formattedMemory() -> String {
        let mb = residentMemoryMB()
        return mb >= 1024
            ? String(format: "%.1f GB", Double(mb) / 1024.0)
            : "\(mb) MB"
    }
}
