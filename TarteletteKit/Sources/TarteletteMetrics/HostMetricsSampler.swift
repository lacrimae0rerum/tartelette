import Darwin
import Foundation
import TarteletteCore

/// Samples whole-host CPU, memory, swap, pressure, thermal state and load.
///
/// CPU usage is computed from tick deltas between consecutive calls; the first call reports the
/// average since boot.
public actor HostMetricsSampler {
  private var previousTicks: CPUTicks?

  public init() {}

  public func sample(at date: Date = .now) -> HostSample {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }

    let ticks = Self.cpuTicks(host: host)
    let cpuPercent: Double
    if let ticks {
      cpuPercent = Self.cpuPercent(from: previousTicks ?? .zero, to: ticks)
      previousTicks = ticks
    } else {
      cpuPercent = 0
    }

    let memory = Self.memory(host: host)
    return HostSample(
      date: date,
      cpuPercent: cpuPercent,
      logicalCores: ProcessInfo.processInfo.activeProcessorCount,
      memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
      memoryUsedBytes: min(memory.used, ProcessInfo.processInfo.physicalMemory),
      memoryCompressedBytes: memory.compressed,
      swapUsedBytes: Self.swapUsedBytes(),
      memoryPressure: Self.memoryPressure(),
      thermalState: Self.thermalState(ProcessInfo.processInfo.thermalState),
      loadAverage: Self.loadAverage()
    )
  }

  // MARK: - CPU

  struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    static let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
  }

  /// Busy share of elapsed ticks in 0...100. Tick counters are 32-bit and may wrap.
  static func cpuPercent(from old: CPUTicks, to new: CPUTicks) -> Double {
    let user = Double(new.user &- old.user)
    let system = Double(new.system &- old.system)
    let nice = Double(new.nice &- old.nice)
    let idle = Double(new.idle &- old.idle)
    let total = user + system + nice + idle
    guard total > 0 else { return 0 }
    return min(100, max(0, (user + system + nice) / total * 100))
  }

  private static func cpuTicks(host: mach_port_t) -> CPUTicks? {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return CPUTicks(
      user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
  }

  // MARK: - Memory

  private static func memory(host: mach_port_t) -> (used: UInt64, compressed: UInt64) {
    var pageSize: vm_size_t = 0
    guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return (0, 0) }

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }

    let page = UInt64(pageSize)
    let compressed = UInt64(stats.compressor_page_count) * page
    let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * page + compressed
    return (used, compressed)
  }

  private static func swapUsedBytes() -> UInt64 {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
    return usage.xsu_used
  }

  static func memoryPressure(level: Int32) -> MemoryPressure {
    switch level {
    case 4...: .critical
    case 2...3: .warning
    default: .normal
    }
  }

  private static func memoryPressure() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
    return memoryPressure(level: level)
  }

  // MARK: - Thermal & load

  static func thermalState(_ state: ProcessInfo.ThermalState) -> HostThermalState {
    switch state {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .nominal
    }
  }

  private static func loadAverage() -> [Double] {
    var values = [Double](repeating: 0, count: 3)
    let count = getloadavg(&values, 3)
    return count > 0 ? Array(values.prefix(Int(count))) : []
  }
}
