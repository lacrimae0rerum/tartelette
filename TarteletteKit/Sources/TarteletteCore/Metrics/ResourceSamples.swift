import Foundation

/// Rates derived from two consecutive usage snapshots of a VM's host processes.
public struct VMResourceSample: Sendable, Equatable, Identifiable {
  public var id: Date { date }
  public var date: Date
  /// CPU usage where 100 equals one fully busy core.
  public var cpuPercent: Double
  /// Share of `cpuPercent` spent in the guest (Virtualization XPC service).
  public var guestCPUPercent: Double
  /// Share of `cpuPercent` spent in the `tart run` process (UI, networking, I/O plumbing).
  public var tartCPUPercent: Double
  /// Physical footprint of all VM processes.
  public var memoryBytes: UInt64
  public var diskReadBytesPerSecond: Double
  public var diskWriteBytesPerSecond: Double
  public var powerWatts: Double?

  public init(
    date: Date,
    cpuPercent: Double,
    guestCPUPercent: Double,
    tartCPUPercent: Double,
    memoryBytes: UInt64,
    diskReadBytesPerSecond: Double,
    diskWriteBytesPerSecond: Double,
    powerWatts: Double?
  ) {
    self.date = date
    self.cpuPercent = cpuPercent
    self.guestCPUPercent = guestCPUPercent
    self.tartCPUPercent = tartCPUPercent
    self.memoryBytes = memoryBytes
    self.diskReadBytesPerSecond = diskReadBytesPerSecond
    self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    self.powerWatts = powerWatts
  }
}

public enum MemoryPressure: String, Sendable, Equatable, Codable {
  case normal, warning, critical
}

public enum HostThermalState: String, Sendable, Equatable, Codable {
  case nominal, fair, serious, critical
}

/// Whole-host utilisation at one point in time.
public struct HostSample: Sendable, Equatable, Identifiable {
  public var id: Date { date }
  public var date: Date
  /// 0...100 across all cores.
  public var cpuPercent: Double
  public var logicalCores: Int
  public var memoryTotalBytes: UInt64
  public var memoryUsedBytes: UInt64
  public var memoryCompressedBytes: UInt64
  public var swapUsedBytes: UInt64
  public var memoryPressure: MemoryPressure
  public var thermalState: HostThermalState
  public var loadAverage: [Double]

  public init(
    date: Date,
    cpuPercent: Double,
    logicalCores: Int,
    memoryTotalBytes: UInt64,
    memoryUsedBytes: UInt64,
    memoryCompressedBytes: UInt64,
    swapUsedBytes: UInt64,
    memoryPressure: MemoryPressure,
    thermalState: HostThermalState,
    loadAverage: [Double]
  ) {
    self.date = date
    self.cpuPercent = cpuPercent
    self.logicalCores = logicalCores
    self.memoryTotalBytes = memoryTotalBytes
    self.memoryUsedBytes = memoryUsedBytes
    self.memoryCompressedBytes = memoryCompressedBytes
    self.swapUsedBytes = swapUsedBytes
    self.memoryPressure = memoryPressure
    self.thermalState = thermalState
    self.loadAverage = loadAverage
  }
}

/// Disk usage of Tart's storage (TART_HOME) and the volume that holds it.
public struct StorageUsage: Sendable, Equatable {
  public var tartHome: URL
  public var vmsBytes: UInt64
  public var ociCacheBytes: UInt64
  public var ipswCacheBytes: UInt64
  public var otherBytes: UInt64
  public var volumeTotalBytes: UInt64
  public var volumeAvailableBytes: UInt64

  public init(
    tartHome: URL,
    vmsBytes: UInt64,
    ociCacheBytes: UInt64,
    ipswCacheBytes: UInt64,
    otherBytes: UInt64,
    volumeTotalBytes: UInt64,
    volumeAvailableBytes: UInt64
  ) {
    self.tartHome = tartHome
    self.vmsBytes = vmsBytes
    self.ociCacheBytes = ociCacheBytes
    self.ipswCacheBytes = ipswCacheBytes
    self.otherBytes = otherBytes
    self.volumeTotalBytes = volumeTotalBytes
    self.volumeAvailableBytes = volumeAvailableBytes
  }

  public var totalBytes: UInt64 { vmsBytes + ociCacheBytes + ipswCacheBytes + otherBytes }
}

/// Utilisation reported from inside the guest.
public struct GuestSample: Sendable, Equatable, Identifiable {
  public var id: Date { date }
  public var date: Date
  public var cpuPercent: Double?
  public var loadAverage: [Double]
  public var memoryTotalBytes: UInt64?
  public var memoryUsedBytes: UInt64?
  public var diskTotalBytes: UInt64?
  public var diskUsedBytes: UInt64?
  public var uptimeSeconds: Double?
  public var processCount: Int?

  public init(
    date: Date,
    cpuPercent: Double? = nil,
    loadAverage: [Double] = [],
    memoryTotalBytes: UInt64? = nil,
    memoryUsedBytes: UInt64? = nil,
    diskTotalBytes: UInt64? = nil,
    diskUsedBytes: UInt64? = nil,
    uptimeSeconds: Double? = nil,
    processCount: Int? = nil
  ) {
    self.date = date
    self.cpuPercent = cpuPercent
    self.loadAverage = loadAverage
    self.memoryTotalBytes = memoryTotalBytes
    self.memoryUsedBytes = memoryUsedBytes
    self.diskTotalBytes = diskTotalBytes
    self.diskUsedBytes = diskUsedBytes
    self.uptimeSeconds = uptimeSeconds
    self.processCount = processCount
  }
}
