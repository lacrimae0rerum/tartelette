import Foundation
import Observation
import TarteletteKit

/// A VM the user shared with agents, and how.
struct SharedAgentVM: Identifiable, Equatable {
  let name: String
  let access: AgentAccess

  var id: String { name }
}

/// The user's agent settings (`agents.json`), the VMs agents created and their recent activity.
///
/// The `tartelette-mcp` helper reads `agents.json` on every tool call, so each change is saved at
/// once and applies to the agent's next request. A file Tartelette can't read is never
/// overwritten silently: the error is shown and only `resetToDefaults()` replaces it.
@Observable
final class AgentAccessStore {
  let paths: AgentPaths
  private(set) var policy: AgentPolicy = .default
  /// Why `agents.json` couldn't be read. Agents are denied everything meanwhile, and nothing is
  /// saved until the user fixes or resets the file.
  private(set) var loadError: AgentSettingsProblem?
  /// Why the last change couldn't be saved.
  private(set) var saveError: String?
  /// The agent VM registry (`agent-vms.json`) as last read; empty when it can't be read, which
  /// is how agents treat it too.
  private(set) var registeredVMs: [AgentVMEntry] = []
  /// The newest agent tool calls, newest first (see `refreshActivity`).
  private(set) var recentActivity: [AgentAuditEntry] = []

  private let tartPaths: () -> TartPaths
  private var watcher: DirectoryWatcher?

  /// - Parameter tartPaths: Where Tart keeps VMs now (it changes with TART_HOME), used to tell
  ///   whether a VM is still the one an agent created.
  init(paths: AgentPaths = .standard, tartPaths: @escaping () -> TartPaths) {
    self.paths = paths
    self.tartPaths = tartPaths
    reload()
  }

  // MARK: Settings

  /// The master switch: when off, agents can't use any VM.
  var enabled: Bool { policy.enabled }

  func setEnabled(_ enabled: Bool) {
    update { $0.enabled = enabled }
  }

  func access(for name: String) -> AgentAccess { policy.access(for: name) }

  /// Sets the level for a VM; `none` removes it from the file.
  func setAccess(_ access: AgentAccess, for name: String) {
    update { $0.vms[name] = access == .none ? nil : access }
  }

  /// VMs shared with agents (any level but `none`), by name.
  var sharedVMs: [SharedAgentVM] {
    policy.vms
      .filter { $0.value != .none }
      .map { SharedAgentVM(name: $0.key, access: $0.value) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Moves a VM's level to its new name after the user renamed it in Tartelette.
  func renameVM(from oldName: String, to newName: String) {
    update { policy in
      guard let access = policy.vms.removeValue(forKey: oldName) else { return }
      policy.vms[newName] = access
    }
  }

  /// Forgets the levels of VMs the user deleted in Tartelette. The agent VM registry is left to
  /// the helper, which prunes VMs that no longer exist.
  func removeVMs(_ names: [String]) {
    update { policy in
      for name in names { policy.vms[name] = nil }
    }
  }

  /// Replaces `agents.json` with the defaults (agents off, nothing shared): the explicit way out
  /// of a file Tartelette can't read.
  func resetToDefaults() {
    save(.default)
  }

  // MARK: VMs created by agents

  /// The registry entry of a VM an agent created, when its directory is still the one the agent
  /// created (a VM recreated under the same name doesn't count). Agents fully control these VMs.
  func creator(of name: String) -> AgentVMEntry? {
    guard let entry = registeredVMs.last(where: { $0.name == name }),
      VMFingerprint.of(vmNamed: name, paths: tartPaths()) == entry.fingerprint
    else { return nil }
    return entry
  }

  /// The VMs agents created that still exist, by name.
  var agentCreatedVMs: [AgentVMEntry] {
    registeredVMs
      .filter { creator(of: $0.name) == $0 }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // MARK: Activity

  /// Re-reads the newest agent tool calls from the audit log, newest first.
  func refreshActivity(limit: Int = 100) {
    let entries = Array(AgentAuditLog(file: paths.auditLogFile).recent(limit: limit).reversed())
    if entries != recentActivity { recentActivity = entries }
  }

  // MARK: Loading

  /// Re-reads `agents.json` and the agent VM registry.
  func reload() {
    reloadPolicy()
    let entries = (try? AgentVMRegistry(paths: paths).entries()) ?? []
    if entries != registeredVMs { registeredVMs = entries }
  }

  /// Reloads whenever a file in the settings folder is replaced: the helper registering a VM it
  /// created, or `agents.json` edited by hand.
  func startWatching() {
    try? FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
    watcher = DirectoryWatcher(url: paths.applicationSupport) { [weak self] in self?.reload() }
  }

  private func reloadPolicy() {
    do {
      let loaded = try AgentPolicyStore(file: paths.policyFile).load()
      if loaded != policy { policy = loaded }
      if loadError != nil { loadError = nil }
    } catch {
      if policy != .default { policy = .default }
      let problem = AgentSettingsProblem(error, contents: try? Data(contentsOf: paths.policyFile))
      if problem != loadError { loadError = problem }
    }
  }

  /// Applies a change to the policy on disk and saves it at once. Starting from the file (not the
  /// copy in memory) keeps edits made elsewhere; a file that can't be read is never overwritten.
  private func update(_ change: (inout AgentPolicy) -> Void) {
    reloadPolicy()
    guard loadError == nil else { return }
    var updated = policy
    change(&updated)
    guard updated != policy else { return }
    save(updated)
  }

  private func save(_ updated: AgentPolicy) {
    do {
      try AgentPolicyStore(file: paths.policyFile).save(updated)
      policy = updated
      loadError = nil
      saveError = nil
    } catch {
      saveError = error.localizedDescription
    }
  }
}
