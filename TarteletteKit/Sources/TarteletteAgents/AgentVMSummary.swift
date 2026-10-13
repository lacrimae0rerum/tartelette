import Foundation

/// A local VM as agents see it. Encoded as JSON for agents, so field names are stable.
public struct AgentVMSummary: Codable, Sendable, Equatable {
  public var name: String
  /// As Tart reports it: `running`, `stopped` or `suspended`.
  public var state: String
  /// `macOS`, `Linux` or `Unknown`, from the VM's `config.json`.
  public var os: String
  public var access: EffectiveAccess
  /// Whether an agent created the VM (and may therefore delete it).
  public var createdByAgent: Bool
  /// Disk capacity in (decimal) gigabytes.
  public var diskGB: Double?
  /// Space used on the host in (decimal) gigabytes.
  public var sizeGB: Double?

  public init(
    name: String,
    state: String,
    os: String,
    access: EffectiveAccess,
    createdByAgent: Bool,
    diskGB: Double?,
    sizeGB: Double?
  ) {
    self.name = name
    self.state = state
    self.os = os
    self.access = access
    self.createdByAgent = createdByAgent
    self.diskGB = diskGB
    self.sizeGB = sizeGB
  }
}

/// What `vm_info` reports: the summary plus the VM's hardware and, while it runs, its address.
public struct AgentVMDetails: Codable, Sendable, Equatable {
  public var summary: AgentVMSummary
  public var cpuCount: Int?
  public var memoryMB: UInt64?
  /// Display size, e.g. `1024x768`.
  public var display: String?
  /// The guest's IPv4 address, when the VM is running and has one.
  public var ipAddress: String?

  public init(summary: AgentVMSummary, cpuCount: Int?, memoryMB: UInt64?, display: String?, ipAddress: String?) {
    self.summary = summary
    self.cpuCount = cpuCount
    self.memoryMB = memoryMB
    self.display = display
    self.ipAddress = ipAddress
  }
}
