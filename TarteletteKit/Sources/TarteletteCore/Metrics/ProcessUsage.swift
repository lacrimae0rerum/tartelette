import Foundation

/// A cumulative resource-usage snapshot of one host process (from `proc_pid_rusage`).
public struct ProcessUsage: Sendable, Equatable {
  public var pid: Int32
  /// Monotonic capture time in nanoseconds (CLOCK_UPTIME_RAW).
  public var capturedAtNanoseconds: UInt64
  /// User + system CPU time, already converted to nanoseconds.
  public var cpuTimeNanoseconds: UInt64
  public var physicalFootprintBytes: UInt64
  public var residentBytes: UInt64
  public var diskBytesRead: UInt64
  public var diskBytesWritten: UInt64
  /// Cumulative energy in nanojoules, when the kernel reports it.
  public var energyNanojoules: UInt64?

  public init(
    pid: Int32,
    capturedAtNanoseconds: UInt64,
    cpuTimeNanoseconds: UInt64,
    physicalFootprintBytes: UInt64,
    residentBytes: UInt64,
    diskBytesRead: UInt64,
    diskBytesWritten: UInt64,
    energyNanojoules: UInt64?
  ) {
    self.pid = pid
    self.capturedAtNanoseconds = capturedAtNanoseconds
    self.cpuTimeNanoseconds = cpuTimeNanoseconds
    self.physicalFootprintBytes = physicalFootprintBytes
    self.residentBytes = residentBytes
    self.diskBytesRead = diskBytesRead
    self.diskBytesWritten = diskBytesWritten
    self.energyNanojoules = energyNanojoules
  }
}

/// The host processes that make up one running VM.
public struct VMProcessSet: Sendable, Equatable {
  /// The `tart run` process holding the VM lock.
  public var tartPID: Int32
  /// Virtualization.framework XPC service processes attributed to `tartPID`.
  public var virtualMachinePIDs: [Int32]

  public init(tartPID: Int32, virtualMachinePIDs: [Int32]) {
    self.tartPID = tartPID
    self.virtualMachinePIDs = virtualMachinePIDs
  }

  public var allPIDs: [Int32] { [tartPID] + virtualMachinePIDs }
}
