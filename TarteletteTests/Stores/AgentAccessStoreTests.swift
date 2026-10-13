import Foundation
import Testing
import TarteletteKit

@testable import Tartelette

/// Agent settings as the app sees them, against scratch `AgentPaths` and `TartPaths`.
@Suite("Agent access store")
final class AgentAccessStoreTests {
  private let root: URL
  private let paths: AgentPaths
  private let tartPaths: TartPaths

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartelette-agent-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    paths = AgentPaths(
      applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true))
    tartPaths = TartPaths(home: root.appendingPathComponent("tart", isDirectory: true))
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeStore() -> AgentAccessStore {
    let tartPaths = tartPaths
    return AgentAccessStore(paths: paths, tartPaths: { tartPaths })
  }

  // MARK: Policy

  @Test func startsOffWithNothingSharedAndWritesNothing() {
    let store = makeStore()
    #expect(!store.enabled)
    #expect(store.sharedVMs.isEmpty)
    #expect(store.access(for: "dev") == .none)
    #expect(store.loadError == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.policyFile.path))
  }

  @Test func theSwitchIsSavedAtOnce() throws {
    makeStore().setEnabled(true)
    #expect(try AgentPolicyStore(file: paths.policyFile).load().enabled)
    #expect(makeStore().enabled)

    makeStore().setEnabled(false)
    #expect(!makeStore().enabled)
  }

  @Test func accessLevelsAreSavedAndNoneRemovesTheEntry() throws {
    let store = makeStore()
    store.setAccess(.operate, for: "dev")
    store.setAccess(.template, for: "base")

    let reloaded = makeStore()
    #expect(reloaded.access(for: "dev") == .operate)
    #expect(reloaded.sharedVMs == [
      SharedAgentVM(name: "base", access: .template), SharedAgentVM(name: "dev", access: .operate),
    ])

    store.setAccess(.none, for: "dev")
    #expect(try AgentPolicyStore(file: paths.policyFile).load().vms == ["base": .template])
    #expect(makeStore().sharedVMs.map(\.name) == ["base"])
  }

  @Test func aMalformedFileIsReportedAndKeptUntilTheUserResetsIt() throws {
    let damaged = Data(#"{"enabled": true, "vms": ["#.utf8)
    try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
    try damaged.write(to: paths.policyFile)

    let store = makeStore()
    #expect(store.loadError != nil)
    #expect(!store.enabled)
    store.setEnabled(true)
    store.setAccess(.operate, for: "dev")
    #expect(try Data(contentsOf: paths.policyFile) == damaged)
    #expect(!store.enabled)

    store.resetToDefaults()
    #expect(store.loadError == nil)
    #expect(try AgentPolicyStore(file: paths.policyFile).load() == .default)
    store.setAccess(.read, for: "dev")
    #expect(makeStore().access(for: "dev") == .read)
  }

  // MARK: VMs created by agents

  @Test func aVMCountsAsAgentCreatedOnlyWhileItsDirectoryMatchesTheRegistry() throws {
    for name in ["sandbox", "recreated"] {
      try FileManager.default.createDirectory(at: tartPaths.vmDirectory(name), withIntermediateDirectories: true)
    }
    let fingerprint = try #require(VMFingerprint.of(vmNamed: "sandbox", paths: tartPaths))
    let registry = AgentVMRegistry(paths: paths)
    try registry.register(
      AgentVMEntry(name: "sandbox", source: "base", client: "claude-code", createdAt: Date(), fingerprint: fingerprint))
    try registry.register(
      AgentVMEntry(name: "recreated", source: "base", client: "codex", createdAt: Date(), fingerprint: "1:2:3.4"))
    try registry.register(
      AgentVMEntry(name: "gone", source: "base", client: nil, createdAt: Date(), fingerprint: fingerprint))

    let store = makeStore()
    #expect(store.creator(of: "sandbox")?.client == "claude-code")
    #expect(store.creator(of: "recreated") == nil)
    #expect(store.creator(of: "gone") == nil)
    #expect(store.agentCreatedVMs.map(\.name) == ["sandbox"])
  }

  // MARK: Activity

  @Test func recentActivityListsTheNewestCallsFirst() throws {
    let log = AgentAuditLog(file: paths.auditLogFile)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for (offset, tool) in ["list_vms", "start_vm", "exec"].enumerated() {
      try log.record(
        AgentAuditEntry(
          date: start.addingTimeInterval(Double(offset)), client: "claude-code", tool: tool, vm: "dev", outcome: .ok))
    }

    let store = makeStore()
    store.refreshActivity(limit: 2)
    #expect(store.recentActivity.map(\.tool) == ["exec", "start_vm"])
  }

  // MARK: Renamed and deleted VMs

  @Test func renamingAVMCarriesItsAccessLevel() {
    let store = makeStore()
    store.setAccess(.template, for: "base")
    store.setAccess(.read, for: "other")

    store.renameVM(from: "base", to: "base-2026")

    let reloaded = makeStore()
    #expect(reloaded.access(for: "base-2026") == .template)
    #expect(reloaded.access(for: "base") == .none)
    #expect(reloaded.access(for: "other") == .read)
  }

  @Test func deletingVMsRemovesTheirEntries() throws {
    let store = makeStore()
    store.setAccess(.operate, for: "a")
    store.setAccess(.read, for: "b")
    store.setAccess(.template, for: "c")

    store.removeVMs(["a", "c", "never-shared"])

    #expect(try AgentPolicyStore(file: paths.policyFile).load().vms == ["b": .read])
  }
}
