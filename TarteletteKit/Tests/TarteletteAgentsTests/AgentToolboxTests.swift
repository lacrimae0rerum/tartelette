import Foundation
import Testing

@testable import TarteletteAgents

@Suite("Agent toolbox: policy, names, listing and inspection")
struct AgentToolboxTests {
  // MARK: Policy and names

  @Test func disabledAgentsAreRefusedWithoutRunningTart() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: false, vms: ["dev": .operate]))
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    await #expect(throws: AgentDenial.agentsDisabled) { try await harness.toolbox.listVMs() }
    await #expect(throws: AgentDenial.agentsDisabled) { try await harness.toolbox.vmInfo(name: "dev") }

    #expect(harness.tart.calls.isEmpty)
    let entries = harness.auditEntries
    #expect(entries.map(\.tool) == ["list_vms", "vm_info"])
    #expect(entries.map(\.outcome) == [.denied, .denied])
    #expect(entries.allSatisfy { $0.client == ToolboxHarness.clientName })
  }

  @Test func missingSettingsMeanAgentsAreOff() async throws {
    let harness = try ToolboxHarness(policy: nil)
    defer { harness.remove() }

    await #expect(throws: AgentDenial.agentsDisabled) { try await harness.toolbox.listVMs() }
    #expect(harness.tart.calls.isEmpty)
  }

  @Test func unreadableSettingsFailClosed() async throws {
    let harness = try ToolboxHarness(policy: nil)
    defer { harness.remove() }
    try FileManager.default.createDirectory(at: harness.agentPaths.applicationSupport, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: harness.agentPaths.policyFile)

    let error = await #expect(throws: AgentToolError.self) { try await harness.toolbox.listVMs() }
    guard case .settingsUnreadable = error else { Issue.record("unexpected \(String(describing: error))"); return }
    #expect(error?.localizedDescription.contains("agent settings couldn't be read") == true)
    #expect(harness.tart.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test func hiddenVMsAreRefusedWithoutRunningTart() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["secret": .none, "dev": .read]))
    defer { harness.remove() }
    try harness.tart.addVM("secret")

    await #expect(throws: AgentDenial.notShared(vm: "secret", operation: .inspect)) {
      try await harness.toolbox.vmInfo(name: "secret")
    }
    #expect(harness.tart.calls.isEmpty)
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "vm_info")
    #expect(entry.vm == "secret")
    #expect(entry.outcome == .denied)
  }

  @Test(arguments: ["-x", "--help", "../a", "a/b", "", "a b", ".hidden", "é", String(repeating: "a", count: 65)])
  func invalidNamesAreRejectedBeforeAnythingRuns(name: String) async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: [name: .operate]))
    defer { harness.remove() }

    await #expect(throws: AgentToolError.invalidName(name)) { try await harness.toolbox.vmInfo(name: name) }
    #expect(harness.tart.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test(arguments: ["a", "dev", "Ubuntu-24.04_arm", String(repeating: "a", count: 64)])
  func validNamesReachTheAuthorizer(name: String) async throws {
    let harness = try ToolboxHarness()
    defer { harness.remove() }

    await #expect(throws: AgentDenial.notShared(vm: name, operation: .inspect)) {
      try await harness.toolbox.vmInfo(name: name)
    }
  }

  @Test func toolNamesMatchTheMCPTools() {
    #expect(
      AgentTool.allCases.map(\.rawValue) == [
        "list_vms", "vm_info", "start_vm", "stop_vm", "create_sandbox", "delete_vm", "exec", "read_file",
        "write_file",
      ])
  }

  // MARK: Listing

  @Test func listingShowsOnlyLocalVMsSharedWithAgents() async throws {
    // The fake also lists this OCI image; sharing it proves it is skipped for being remote.
    let image = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
    let harness = try ToolboxHarness(
      policy: AgentPolicy(
        enabled: true, vms: ["base": .template, "dev": .operate, "ubuntu": .read, "secret": .none, image: .read]))
    defer { harness.remove() }
    try harness.tart.addVM("base")
    try harness.tart.addVM("dev", state: "running")
    try harness.tart.addVM("secret")
    try harness.tart.addVM("ubuntu", os: "linux", state: "suspended")
    try harness.tart.addVM("unlisted")

    let vms = try await harness.toolbox.listVMs()

    #expect(
      vms == [
        AgentVMSummary(
          name: "base", state: "stopped", os: "macOS", access: .template, createdByAgent: false, diskGB: 50, sizeGB: 12),
        AgentVMSummary(
          name: "dev", state: "running", os: "macOS", access: .operate, createdByAgent: false, diskGB: 50, sizeGB: 12),
        AgentVMSummary(
          name: "ubuntu", state: "suspended", os: "Linux", access: .read, createdByAgent: false, diskGB: 50, sizeGB: 12),
      ])
    // Only `tart list`: the OS comes from config.json, never from `tart get`.
    #expect(harness.tart.calls.allSatisfy { $0.hasPrefix("list") })
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "list_vms")
    #expect(entry.vm == nil)
    #expect(entry.outcome == .ok)
  }

  @Test func agentVMsAreListedAsOwnedUntilTheirDirectoryIsReplaced() async throws {
    let harness = try ToolboxHarness()
    defer { harness.remove() }
    try harness.tart.addVM("sandbox")
    try harness.tart.addVM("reused")
    try harness.registerAgentVM("sandbox")
    try harness.registerAgentVM("reused")
    try FileManager.default.removeItem(at: harness.tart.paths.vmDirectory("reused"))
    try harness.tart.addVM("reused")

    let vms = try await harness.toolbox.listVMs()

    #expect(vms.map(\.name) == ["sandbox"])
    #expect(vms.first?.access == .owned)
    #expect(vms.first?.createdByAgent == true)
  }

  @Test func listingForgetsAgentVMsThatNoLongerExist() async throws {
    let harness = try ToolboxHarness()
    defer { harness.remove() }
    try harness.tart.addVM("sandbox")
    try harness.registerAgentVM("sandbox")
    try harness.tart.addVM("gone")
    try harness.registerAgentVM("gone")
    try FileManager.default.removeItem(at: harness.tart.paths.vmDirectory("gone"))

    _ = try await harness.toolbox.listVMs()

    #expect(try harness.registry.entries().map(\.name) == ["sandbox"])
  }

  @Test func summariesEncodeWithStableFieldNames() throws {
    let summary = AgentVMSummary(
      name: "dev", state: "running", os: "macOS", access: .owned, createdByAgent: true, diskGB: 50, sizeGB: nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let json = String(decoding: try encoder.encode(summary), as: UTF8.self)
    #expect(
      json == #"{"access":"owned","createdByAgent":true,"diskGB":50,"name":"dev","os":"macOS","state":"running"}"#)
  }

  // MARK: Inspection

  @Test func inspectingARunningVMReportsItsConfigurationAndAddress() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .read]))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")

    let info = try await harness.toolbox.vmInfo(name: "dev")

    #expect(
      info
        == AgentVMDetails(
          summary: AgentVMSummary(
            name: "dev", state: "running", os: "macOS", access: .read, createdByAgent: false, diskGB: 50, sizeGB: 12),
          cpuCount: 4, memoryMB: 8192, display: "1024x768", ipAddress: "192.168.64.7"))
    #expect(harness.tart.calls.contains("ip dev --wait 2"))
    #expect(!harness.tart.calls.contains { $0.hasPrefix("get") })
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "vm_info")
    #expect(entry.vm == "dev")
    #expect(entry.outcome == .ok)
  }

  @Test func inspectingAStoppedVMSkipsTheAddress() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .read]))
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    let info = try await harness.toolbox.vmInfo(name: "dev")

    #expect(info.ipAddress == nil)
    #expect(info.summary.state == "stopped")
    #expect(!harness.tart.calls.contains { $0.hasPrefix("ip") })
  }

  @Test func inspectingAMissingSharedVMSaysItDoesNotExist() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .read]))
    defer { harness.remove() }

    await #expect(throws: AgentToolError.vmNotFound("dev")) { try await harness.toolbox.vmInfo(name: "dev") }
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  // MARK: Guest readiness

  @Test func defaultReadinessRunsTrueThroughTartExec() async throws {
    let harness = try ToolboxHarness()
    defer { harness.remove() }
    let readiness = AgentToolbox.tartExecReadiness(environment: harness.tart.environment)

    #expect(await readiness("dev") == false)
    try harness.tart.setFlag("agent-answers")
    #expect(await readiness("dev") == true)
    #expect(harness.tart.calls == ["exec dev true", "exec dev true"])
  }
}
