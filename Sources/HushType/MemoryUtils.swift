import Darwin
import Foundation

/// Utility to read the current process's physical memory footprint.
enum MemoryUtils {
    /// Returns `phys_footprint` in megabytes — the same counter Activity
    /// Monitor's Memory column uses. The previous implementation read
    /// `mach_task_basic_info.resident_size`, which does NOT count Metal/GPU
    /// buffer pages that were faulted by the GPU — i.e. the MLX-held Qwen3
    /// weights — so the menu showed <100 MB with a ~2 GB model loaded.
    /// (Verified empirically: 1 GB of GPU-blit-filled MTLBuffers shows up in
    /// phys_footprint but not in resident_size.)
    static func physFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// Human-readable string: "2.1 GB" or "48 MB".
    static func formattedMemory() -> String {
        let mb = physFootprintMB()
        return mb >= 1024
            ? String(format: "%.1f GB", Double(mb) / 1024.0)
            : "\(mb) MB"
    }
}
