import Foundation

public enum VMState: Sendable, Hashable {
  case running
  case suspended
  case stopped
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.lowercased() {
    case "running": self = .running
    case "suspended": self = .suspended
    case "stopped": self = .stopped
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .running: "running"
    case .suspended: "suspended"
    case .stopped: "stopped"
    case .unknown(let value): value
    }
  }

  public var isRunning: Bool { self == .running }
}

public enum VMSource: String, Sendable, Hashable, CaseIterable {
  /// A VM in `~/.tart/vms`.
  case local
  /// A pulled image in the OCI cache (`~/.tart/cache/OCIs`).
  case oci
}

public enum VMOperatingSystem: String, Sendable, Hashable, Codable {
  case macOS = "darwin"
  case linux
  case unknown

  public init(tartValue: String) {
    self = VMOperatingSystem(rawValue: tartValue.lowercased()) ?? .unknown
  }

  public var displayName: String {
    switch self {
    case .macOS: "macOS"
    case .linux: "Linux"
    case .unknown: "Unknown"
    }
  }
}

public enum DiskFormat: String, Sendable, Hashable, CaseIterable, Codable {
  case raw
  /// Apple Sparse Image Format; requires a macOS 26 host.
  case asif
}

/// One row of `tart list --format json`.
public struct VMListing: Sendable, Hashable, Identifiable {
  public var id: String { "\(source.rawValue):\(name)" }
  public var name: String
  public var source: VMSource
  /// Logical disk capacity in (decimal) gigabytes.
  public var diskGB: Double?
  /// Space actually allocated on the host in (decimal) gigabytes.
  public var sizeGB: Double?
  public var lastAccessed: Date?
  public var state: VMState

  public init(
    name: String,
    source: VMSource,
    diskGB: Double?,
    sizeGB: Double?,
    lastAccessed: Date?,
    state: VMState
  ) {
    self.name = name
    self.source = source
    self.diskGB = diskGB
    self.sizeGB = sizeGB
    self.lastAccessed = lastAccessed
    self.state = state
  }
}

/// The output of `tart get <name> --format json`.
public struct VMDetails: Sendable, Hashable {
  public var os: VMOperatingSystem
  public var cpuCount: Int
  public var memoryMB: UInt64
  public var diskGB: Double?
  public var diskFormat: String
  public var sizeGB: Double?
  public var display: String
  public var state: VMState

  public init(
    os: VMOperatingSystem,
    cpuCount: Int,
    memoryMB: UInt64,
    diskGB: Double?,
    diskFormat: String,
    sizeGB: Double?,
    display: String,
    state: VMState
  ) {
    self.os = os
    self.cpuCount = cpuCount
    self.memoryMB = memoryMB
    self.diskGB = diskGB
    self.diskFormat = diskFormat
    self.sizeGB = sizeGB
    self.display = display
    self.state = state
  }
}

/// The subset of a VM bundle's `config.json` that the app uses.
public struct VMConfigFile: Sendable, Hashable, Codable {
  public struct Display: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var unit: String?
  }

  public var version: Int?
  public var os: String
  public var arch: String?
  public var cpuCount: Int
  public var cpuCountMin: Int?
  public var memorySize: UInt64
  public var memorySizeMin: UInt64?
  public var macAddress: String?
  public var display: Display?
  public var displayRefit: Bool?
  public var diskFormat: String?

  public var operatingSystem: VMOperatingSystem { VMOperatingSystem(tartValue: os) }
}

public enum VMNameValidation {
  /// Returns a user-facing problem with a proposed local VM name, or nil when it is acceptable.
  public static func problem(with name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Enter a name." }
    if trimmed != name { return "Names can't start or end with spaces." }
    if name.hasPrefix("-") { return "Names can't start with a hyphen." }
    if name.contains("/") || name.contains(":") { return "Local VM names can't contain “/” or “:”." }
    if name.contains(where: \.isNewline) { return "Names must be a single line." }
    if name == "." || name == ".." { return "That name is reserved." }
    return nil
  }
}
