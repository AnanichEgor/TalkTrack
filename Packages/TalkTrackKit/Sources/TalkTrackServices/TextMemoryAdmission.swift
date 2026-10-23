import Darwin
import Foundation
import TalkTrackDomain

public struct NativeMemorySnapshot: Codable, Sendable {
    public let physicalBytes: UInt64
    public let reclaimableBytes: UInt64
    public let footprintBytes: UInt64
    public let peakResidentBytes: UInt64
    public let pressure: Int32
    public let swapUsedBytes: UInt64

    public init(physicalBytes: UInt64, reclaimableBytes: UInt64, footprintBytes: UInt64,
                peakResidentBytes: UInt64, pressure: Int32, swapUsedBytes: UInt64 = 0) {
        self.physicalBytes = physicalBytes; self.reclaimableBytes = reclaimableBytes
        self.footprintBytes = footprintBytes; self.peakResidentBytes = peakResidentBytes
        self.pressure = pressure; self.swapUsedBytes = swapUsedBytes
    }

    public static func current() throws -> Self {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var task = task_vm_info_data_t()
        var taskCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let taskResult = withUnsafeMutablePointer(to: &task) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(taskCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &taskCount)
            }
        }
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout.size(ofValue: pressure)
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        guard swapResult == 0, pageResult == KERN_SUCCESS, pageSize > 0, result == KERN_SUCCESS, taskResult == KERN_SUCCESS, pressureResult == 0 else {
            throw TextMemoryAdmissionError.unavailable
        }
        // Do not count compressor, swap, or all nominal free process address space
        // as available physical RAM. Leave inactive-page reclamation to macOS.
        return Self(physicalBytes: ProcessInfo.processInfo.physicalMemory,
            reclaimableBytes: (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(pageSize),
            footprintBytes: task.phys_footprint, peakResidentBytes: task.resident_size_peak, pressure: pressure, swapUsedBytes: swap.xsu_used)
    }
}

public enum TextMemoryAdmissionError: Error, LocalizedError, Equatable {
    case unavailable, unsafe
    /// macOS reports critical memory pressure: it can no longer make room.
    case pressure

    public var errorDescription: String? {
        let advice = "The source has not been changed or truncated."
        return switch self {
        case .unavailable: "Memory availability cannot be checked. Text processing was not started."
        case .unsafe: "This text request does not fit in this Mac's memory. Choose a smaller context in Settings ▸ Text, or the 4B text model in Settings ▸ Models. " + advice
        case .pressure: "macOS is critically short of memory, so text processing stopped. Quit memory-heavy apps and try again. " + advice
        }
    }
}

public enum TextMemoryProfile: String, Codable, Sendable {
    case qwen36MoE35B, qwen35Dense9B, qwen35Dense4B
    /// Qwen3-4B (all layers full attention); comparison candidates only.
    case qwen3Dense4B
    /// Gemma 3 4B: 5 of 34 layers attend globally; the 29 sliding layers keep
    /// 1,024 tokens (~0.12 GiB), counted as one more layer. Comparison only.
    case gemma3Dense4B
    /// Gemma 4 E4B: only the first 24 of 42 layers keep K/V (the rest share it);
    /// 4 of those attend globally (head 512, 2 KV heads), the 20 sliding layers
    /// keep 512 tokens (~0.04 GiB, within the workspace). Comparison only.
    case gemma4E4B
    var attentionLayers: UInt64 { switch self { case .qwen35Dense9B, .qwen35Dense4B: 8; case .qwen36MoE35B: 10; case .qwen3Dense4B: 36; case .gemma3Dense4B: 6; case .gemma4E4B: 4 } }
    var keyValueHeads: UInt64 { switch self { case .qwen35Dense9B, .qwen35Dense4B, .gemma3Dense4B: 4; case .qwen36MoE35B, .gemma4E4B: 2; case .qwen3Dense4B: 8 } }
    var headDimension: UInt64 { switch self { case .qwen3Dense4B: 128; case .gemma4E4B: 512; default: 256 } }
    /// Prefill workspace above weights and KV. Qwen3.5-4B measured 1.64 GiB at
    /// 32K and 2.76 GiB at 64K beyond weights and KV; the others keep 4 GiB.
    var workspaceGiB: UInt64 { self == .qwen35Dense4B ? 3 : 4 }
}

public enum TextMemoryAdmission {
    private static let gib: UInt64 = 1 << 30
    /// Resident checkpoint plus conservative prefill workspace and exact upper
    /// bound for the validated checkpoint's full-attention KV layers (fp16 K/V).
    public static func estimate(weightBytes: Int64, contextTokens: Int,
                                profile: TextMemoryProfile = .qwen36MoE35B) throws -> UInt64 {
        guard weightBytes > 0, weightBytes < Int64.max / 2,
              ContextLimit.supports(tokenCount: contextTokens) else { throw TextMemoryAdmissionError.unsafe }
        return UInt64(weightBytes) + profile.workspaceGiB * gib +
            UInt64(contextTokens) * profile.attentionLayers * 2 * profile.keyValueHeads * profile.headDimension * 2
    }

    /// Decided by the Mac's RAM, not by what is free right now: macOS compresses
    /// and swaps other apps' memory to make room for the model. A request is
    /// refused only when it could not fit in RAM beside the system reserve, or
    /// when macOS already reports critical pressure (it has nothing left to
    /// reclaim). A model larger than the Mac's default may still be tried; it can
    /// be slow because macOS swaps (Settings ▸ Models warns about this).
    public static func admit(weightBytes: Int64, contextTokens: Int, alreadyLoaded: Bool,
                             memory: NativeMemorySnapshot, profile: TextMemoryProfile = .qwen36MoE35B) throws {
        let estimate = try estimate(weightBytes: weightBytes, contextTokens: contextTokens, profile: profile)
        guard estimate <= usableBytes(memory.physicalBytes) else { throw TextMemoryAdmissionError.unsafe }
        guard memory.pressure < criticalPressure else { throw TextMemoryAdmissionError.pressure }
    }

    /// RAM minus what macOS and the capture path keep: RAM/8, 2–8 GiB.
    static func usableBytes(_ physical: UInt64) -> UInt64 {
        let reserve = min(max(physical / 8, 2 * gib), 8 * gib)
        return physical > reserve ? physical - reserve : 0
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static let criticalPressure: Int32 = 4

    /// Called between bounded GPU batches. Stops without publishing an
    /// incomplete result, never clipping the input, when macOS reaches critical
    /// pressure or this process grows past RAM minus the system reserve.
    public static func checkDuringGeneration(_ memory: NativeMemorySnapshot) throws {
        guard memory.pressure < criticalPressure, memory.footprintBytes <= usableBytes(memory.physicalBytes) else {
            throw TextMemoryAdmissionError.pressure
        }
    }
}
