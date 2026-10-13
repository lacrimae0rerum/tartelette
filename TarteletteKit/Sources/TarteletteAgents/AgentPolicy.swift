import Foundation

/// What the user lets agents do with one VM.
public enum AgentAccess: String, Sendable, Hashable, CaseIterable, Codable {
  /// Hidden from agents.
  case none
  /// Agents may inspect the VM.
  case read
  /// Agents may start and stop the VM, run commands and transfer files.
  case operate
  /// Agents may inspect the VM and clone new VMs from it.
  case template

  /// Unknown values decode as `none`, so a newer or damaged policy never grants more access.
  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = AgentAccess(rawValue: raw) ?? .none
  }
}

/// Resource limits applied to agent tool calls.
///
/// Missing or non-positive values take the defaults, and the default exec timeout never exceeds
/// the maximum.
public struct AgentLimits: Codable, Sendable, Equatable {
  public static let defaultExecTimeoutSeconds = 120
  public static let defaultExecTimeoutMaxSeconds = 1800
  public static let defaultMaxOutputBytes = 262_144
  public static let defaultMaxFileBytes = 52_428_800
  public static let defaultMaxAgentVMs = 4

  /// Timeout for a command when the agent doesn't ask for one.
  public var execTimeoutDefaultSeconds: Int
  /// The longest timeout an agent may ask for.
  public var execTimeoutMaxSeconds: Int
  /// Output kept per stream (stdout, stderr) of a command.
  public var maxOutputBytes: Int
  /// Largest file an agent may write to a VM. Reads aren't capped by it: agents read files in
  /// pages of at most `maxOutputBytes`.
  public var maxFileBytes: Int
  /// How many agent-created VMs may exist at once.
  public var maxAgentVMs: Int

  public init(
    execTimeoutDefaultSeconds: Int = AgentLimits.defaultExecTimeoutSeconds,
    execTimeoutMaxSeconds: Int = AgentLimits.defaultExecTimeoutMaxSeconds,
    maxOutputBytes: Int = AgentLimits.defaultMaxOutputBytes,
    maxFileBytes: Int = AgentLimits.defaultMaxFileBytes,
    maxAgentVMs: Int = AgentLimits.defaultMaxAgentVMs
  ) {
    func positive(_ value: Int, or fallback: Int) -> Int { value > 0 ? value : fallback }
    let maxTimeout = positive(execTimeoutMaxSeconds, or: Self.defaultExecTimeoutMaxSeconds)
    self.execTimeoutMaxSeconds = maxTimeout
    self.execTimeoutDefaultSeconds = min(positive(execTimeoutDefaultSeconds, or: Self.defaultExecTimeoutSeconds), maxTimeout)
    self.maxOutputBytes = positive(maxOutputBytes, or: Self.defaultMaxOutputBytes)
    self.maxFileBytes = positive(maxFileBytes, or: Self.defaultMaxFileBytes)
    self.maxAgentVMs = positive(maxAgentVMs, or: Self.defaultMaxAgentVMs)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      execTimeoutDefaultSeconds: try container.decodeIfPresent(Int.self, forKey: .execTimeoutDefaultSeconds) ?? 0,
      execTimeoutMaxSeconds: try container.decodeIfPresent(Int.self, forKey: .execTimeoutMaxSeconds) ?? 0,
      maxOutputBytes: try container.decodeIfPresent(Int.self, forKey: .maxOutputBytes) ?? 0,
      maxFileBytes: try container.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? 0,
      maxAgentVMs: try container.decodeIfPresent(Int.self, forKey: .maxAgentVMs) ?? 0)
  }
}

/// The user's agent settings (`agents.json`): the master switch, per-VM access and limits.
public struct AgentPolicy: Codable, Sendable, Equatable {
  public static let currentVersion = 1
  /// Agents are off and no VM is shared.
  public static let `default` = AgentPolicy()

  public var version: Int
  /// The master switch; when off, every agent operation is denied.
  public var enabled: Bool
  /// Access per VM name; a VM that isn't listed has no access.
  public var vms: [String: AgentAccess]
  public var limits: AgentLimits

  public init(
    version: Int = AgentPolicy.currentVersion,
    enabled: Bool = false,
    vms: [String: AgentAccess] = [:],
    limits: AgentLimits = AgentLimits()
  ) {
    self.version = version
    self.enabled = enabled
    self.vms = vms
    self.limits = limits
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
      vms: try container.decodeIfPresent([String: AgentAccess].self, forKey: .vms) ?? [:],
      limits: try container.decodeIfPresent(AgentLimits.self, forKey: .limits) ?? AgentLimits())
  }

  /// The level the user set for a VM, `none` when it isn't listed.
  public func access(for name: String) -> AgentAccess {
    vms[name] ?? AgentAccess.none
  }
}

/// A problem reading or writing an agent settings file. Callers treat it as "deny everything".
public enum AgentStoreError: Error, Sendable, Equatable, LocalizedError {
  case unreadable(file: String, detail: String)
  case malformed(file: String, detail: String)
  case unwritable(file: String, detail: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let file, let detail): "Tartelette couldn't read \(file): \(detail)"
    case .malformed(let file, let detail): "Tartelette couldn't understand \(file): \(detail)"
    case .unwritable(let file, let detail): "Tartelette couldn't save \(file): \(detail)"
    }
  }
}

/// Loads and saves `agents.json`.
public struct AgentPolicyStore: Sendable {
  public let file: URL

  public init(file: URL) {
    self.file = file
  }

  /// The saved policy, or `.default` when there is no file yet.
  ///
  /// - Throws: `AgentStoreError` when the file exists but can't be read or decoded.
  public func load() throws -> AgentPolicy {
    guard let data = try AgentJSONFile.read(file) else { return .default }
    return try AgentJSONFile.decode(AgentPolicy.self, from: data, file: file)
  }

  /// Writes pretty-printed, key-sorted JSON atomically, creating the directory if needed.
  public func save(_ policy: AgentPolicy) throws {
    try AgentJSONFile.write(policy, to: file)
  }
}

/// JSON file helpers shared by the agent stores.
enum AgentJSONFile {
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// The file's contents, or nil when it doesn't exist.
  static func read(_ file: URL) throws -> Data? {
    do {
      return try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw AgentStoreError.unreadable(file: file.lastPathComponent, detail: error.localizedDescription)
    }
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, file: URL) throws -> Value {
    do {
      return try decoder().decode(type, from: data)
    } catch {
      throw AgentStoreError.malformed(file: file.lastPathComponent, detail: String(describing: error))
    }
  }

  /// Encodes and replaces the file atomically (temporary file + rename).
  static func write<Value: Encodable>(_ value: Value, to file: URL) throws {
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder().encode(value).write(to: file, options: .atomic)
    } catch {
      throw AgentStoreError.unwritable(file: file.lastPathComponent, detail: error.localizedDescription)
    }
  }
}
