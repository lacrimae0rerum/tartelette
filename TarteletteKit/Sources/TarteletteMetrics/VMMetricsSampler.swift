import Foundation
import TarteletteCore

/// Turns cumulative per-process usage into per-VM rates.
///
/// Each call compares every process with its snapshot from the previous call. A VM is omitted
/// until at least one of its processes has a previous snapshot (the first call only primes
/// state); processes that appear later contribute memory immediately and rates from their second
/// sighting. Counter resets (a reused PID or restarted process) contribute zero, never negatives.
public actor VMMetricsSampler {
  /// Executable name of Tart's userspace networking helper, a child of `tart run`.
  static let softnetName = "softnet"

  private let resolver: VMProcessResolver
  private let table: any ProcessTable
  private var previous: [Int32: ProcessUsage] = [:]
  /// Start time of each sampled pid, so a reused pid never yields a delta against another process.
  private var previousStartTimes: [Int32: UInt64] = [:]

  public init(paths: TartPaths, table: some ProcessTable = SystemProcessTable()) {
    self.init(resolver: VMProcessResolver(paths: paths, table: table), table: table)
  }

  init(resolver: VMProcessResolver, table: any ProcessTable) {
    self.resolver = resolver
    self.table = table
  }

  public func sample(vms names: [String], at date: Date = .now) -> [String: VMResourceSample] {
    var results: [String: VMResourceSample] = [:]
    var current: [Int32: ProcessUsage] = [:]
    var currentStartTimes: [Int32: UInt64] = [:]

    /// The previous snapshot of `pid`, unless the pid now belongs to a different process.
    func baseline(_ pid: Int32) -> ProcessUsage? {
      let start = table.startTime(of: pid)
      if let start { currentStartTimes[pid] = start }
      if let start, let before = previousStartTimes[pid], before != start { return nil }
      return previous[pid]
    }

    for name in names {
      guard let set = resolver.processes(forVM: name) else { continue }
      let softnetPIDs = table.childPIDs(of: set.tartPID).filter { pid in
        table.executablePath(of: pid).map { ($0 as NSString).lastPathComponent == Self.softnetName } ?? false
      }

      var guest = RateAccumulator()
      var tart = RateAccumulator()
      // Each pid is read once per call, even if it were listed twice.
      for pid in set.virtualMachinePIDs where current[pid] == nil {
        guest.add(table.usage(of: pid), previous: baseline(pid), recordingInto: &current)
      }
      for pid in [set.tartPID] + softnetPIDs where current[pid] == nil {
        tart.add(table.usage(of: pid), previous: baseline(pid), recordingInto: &current)
      }

      guard guest.hasRates || tart.hasRates else { continue }
      results[name] = VMResourceSample(
        date: date,
        cpuPercent: guest.cpuPercent + tart.cpuPercent,
        guestCPUPercent: guest.cpuPercent,
        tartCPUPercent: tart.cpuPercent,
        memoryBytes: guest.memoryBytes + tart.memoryBytes,
        diskReadBytesPerSecond: guest.readRate + tart.readRate,
        diskWriteBytesPerSecond: guest.writeRate + tart.writeRate,
        powerWatts: guest.hasEnergy || tart.hasEnergy ? guest.watts + tart.watts : nil
      )
    }

    previous = current
    previousStartTimes = currentStartTimes
    return results
  }

  /// The processes currently attributed to a VM (see `VMProcessResolver`).
  public func processes(forVM name: String) -> VMProcessSet? {
    resolver.processes(forVM: name)
  }

  /// Forgets all snapshots and cached attributions.
  public func reset() {
    previous.removeAll()
    previousStartTimes.removeAll()
    resolver.invalidate()
  }
}

/// Sums rates of a group of processes between two snapshots.
struct RateAccumulator {
  var cpuPercent = 0.0
  var memoryBytes: UInt64 = 0
  var readRate = 0.0
  var writeRate = 0.0
  var watts = 0.0
  var hasRates = false
  var hasEnergy = false

  mutating func add(
    _ usage: ProcessUsage?, previous: ProcessUsage?, recordingInto current: inout [Int32: ProcessUsage]
  ) {
    guard let usage else { return }
    current[usage.pid] = usage
    memoryBytes += usage.physicalFootprintBytes

    guard let previous, usage.capturedAtNanoseconds > previous.capturedAtNanoseconds else { return }
    hasRates = true
    let elapsed = Double(usage.capturedAtNanoseconds - previous.capturedAtNanoseconds)
    cpuPercent += Double(Self.delta(usage.cpuTimeNanoseconds, previous.cpuTimeNanoseconds)) / elapsed * 100
    readRate += Double(Self.delta(usage.diskBytesRead, previous.diskBytesRead)) / elapsed * 1e9
    writeRate += Double(Self.delta(usage.diskBytesWritten, previous.diskBytesWritten)) / elapsed * 1e9
    if let energy = usage.energyNanojoules, let previousEnergy = previous.energyNanojoules {
      hasEnergy = true
      // nJ / ns = J / s = W
      watts += Double(Self.delta(energy, previousEnergy)) / elapsed
    }
  }

  private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
    current >= previous ? current - previous : 0
  }
}
