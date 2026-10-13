import Foundation

/// Something an agent can ask to do with a VM.
public enum AgentOperation: String, Sendable, Hashable, CaseIterable {
  case inspect
  case start
  case stop
  case exec
  case readFile
  case writeFile
  case cloneFrom
  case delete

  /// Completes "which doesn't allow …" in denial messages.
  var phrase: String {
    switch self {
    case .inspect: "inspecting it"
    case .start: "starting it"
    case .stop: "stopping it"
    case .exec: "running commands in it"
    case .readFile: "reading its files"
    case .writeFile: "writing files to it"
    case .cloneFrom: "cloning it"
    case .delete: "deleting it"
    }
  }

  /// The lowest level the user can set to allow this operation; nil when no level allows it.
  var requiredAccess: AgentAccess? {
    switch self {
    case .inspect: .read
    case .start, .stop, .exec, .readFile, .writeFile: .operate
    case .cloneFrom: .template
    case .delete: nil
    }
  }
}

/// The access an agent actually has to a VM: the user's level, or `owned` for a VM an agent created.
public enum EffectiveAccess: String, Sendable, Hashable, CaseIterable, Codable {
  case none
  case read
  case operate
  case template
  /// Created by an agent and still the same VM directory.
  case owned

  public init(_ access: AgentAccess) {
    switch access {
    case .none: self = .none
    case .read: self = .read
    case .operate: self = .operate
    case .template: self = .template
    }
  }

  public var allowedOperations: Set<AgentOperation> {
    switch self {
    case .none: []
    case .read: [.inspect]
    case .operate: [.inspect, .start, .stop, .exec, .readFile, .writeFile]
    case .template: [.inspect, .cloneFrom]
    case .owned: [.inspect, .start, .stop, .exec, .readFile, .writeFile, .delete]
    }
  }

  /// The level's name as the app shows it.
  public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Why an agent operation was refused, phrased for a person reading the agent's transcript.
public enum AgentDenial: Error, Sendable, Equatable, LocalizedError {
  case agentsDisabled
  case notShared(vm: String, operation: AgentOperation)
  case notPermitted(vm: String, operation: AgentOperation, access: EffectiveAccess)
  case notOwned(vm: String)

  public var errorDescription: String? {
    switch self {
    case .agentsDisabled:
      return "Agent access is turned off. Turn it on in Tartelette › Settings › Agents."
    case .notShared(let vm, let operation):
      return "VM “\(vm)” isn't shared with agents." + Self.suggestion(for: operation)
    case .notPermitted(let vm, _, .owned):
      // Cloning is the only operation an owned VM doesn't allow.
      return "VM “\(vm)” was created by an agent, and agents can't clone VMs they created. "
        + "Clone from a VM shared as Template instead."
    case .notPermitted(let vm, let operation, let access):
      return "VM “\(vm)” is shared with agents as \(access.title), which doesn't allow \(operation.phrase)."
        + Self.suggestion(for: operation)
    case .notOwned(let vm):
      return "Agents can only delete VMs they created; “\(vm)” wasn't created by an agent."
    }
  }

  private static func suggestion(for operation: AgentOperation) -> String {
    guard let level = operation.requiredAccess else { return "" }
    return " In Tartelette, set its agent access to \(EffectiveAccess(level).title)."
  }
}

/// Decides what agents may do with each VM, from the user's policy and the agent VM registry.
///
/// A VM is `owned` when the registry lists it and its directory still has the registered
/// fingerprint; otherwise the policy level applies. Only owned VMs can be deleted.
public struct AgentAuthorizer: Sendable {
  public let policy: AgentPolicy
  private let ownedFingerprints: [String: String]

  public init(policy: AgentPolicy, registry entries: [AgentVMEntry]) {
    self.policy = policy
    self.ownedFingerprints = Dictionary(entries.map { ($0.name, $0.fingerprint) }, uniquingKeysWith: { _, last in last })
  }

  /// The access to a VM, ignoring the master switch.
  ///
  /// - Parameter fingerprint: The VM directory's current `VMFingerprint`, nil when it has none.
  public func effectiveAccess(for name: String, fingerprint: String?) -> EffectiveAccess {
    if let fingerprint, ownedFingerprints[name] == fingerprint { return .owned }
    return EffectiveAccess(policy.access(for: name))
  }

  /// Throws when an agent may not perform `operation` on the VM.
  public func check(_ operation: AgentOperation, vm name: String, fingerprint: String?) throws(AgentDenial) {
    guard policy.enabled else { throw .agentsDisabled }
    let access = effectiveAccess(for: name, fingerprint: fingerprint)
    if access.allowedOperations.contains(operation) { return }
    if operation == .delete { throw .notOwned(vm: name) }
    if access == .none { throw .notShared(vm: name, operation: operation) }
    throw .notPermitted(vm: name, operation: operation, access: access)
  }

  /// The access to each VM agents may see; hidden VMs are left out, and nothing is visible while
  /// agents are turned off.
  public func visibleAccess(for names: [String], fingerprints: [String: String]) -> [String: EffectiveAccess] {
    guard policy.enabled else { return [:] }
    var visible: [String: EffectiveAccess] = [:]
    for name in names {
      let access = effectiveAccess(for: name, fingerprint: fingerprints[name])
      if access != .none { visible[name] = access }
    }
    return visible
  }
}
