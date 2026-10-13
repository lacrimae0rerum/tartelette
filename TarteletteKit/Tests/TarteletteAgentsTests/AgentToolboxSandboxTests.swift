import Foundation
import Testing
import os

@testable import TarteletteAgents

@Suite("Agent toolbox: sandboxes and deletion")
struct AgentToolboxSandboxTests {
  private static func harness(
    sharing vms: [String: AgentAccess] = ["base": .template],
    maxAgentVMs: Int = AgentLimits.defaultMaxAgentVMs,
    realPause: Duration = .milliseconds(10)
  ) throws -> ToolboxHarness {
    try ToolboxHarness(
      policy: AgentPolicy(enabled: true, vms: vms, limits: AgentLimits(maxAgentVMs: maxAgentVMs)), realPause: realPause)
  }

  private static func cloneCalls(_ harness: ToolboxHarness) -> [String] {
    harness.tart.calls.filter { $0.hasPrefix("clone") }
  }

  // MARK: Create

  @Test func sandboxesCloneOnlyFromTemplates() async throws {
    let harness = try Self.harness(sharing: ["base": .operate])
    defer { harness.remove() }
    try harness.tart.addVM("base")

    await #expect(throws: AgentDenial.notPermitted(vm: "base", operation: .cloneFrom, access: .operate)) {
      try await harness.toolbox.createSandbox(from: "base")
    }
    #expect(harness.tart.calls.isEmpty)
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "create_sandbox")
    #expect(entry.outcome == .denied)
  }

  @Test func sandboxSourceMustBeStopped() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("base", state: "running")

    let error = await #expect(throws: AgentToolError.sourceNotStopped("base")) {
      try await harness.toolbox.createSandbox(from: "base")
    }
    #expect(error?.localizedDescription == "Stop “base” before cloning it.")
    #expect(Self.cloneCalls(harness).isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test func sandboxIsClonedRegisteredAndReportsProgress() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("base")
    let fractions = OSAllocatedUnfairLock(initialState: [Double]())

    let summary = try await harness.toolbox.createSandbox(from: "base", name: "box") { fraction in
      fractions.withLock { $0.append(fraction) }
    }

    #expect(
      summary
        == AgentVMSummary(
          name: "box", state: "stopped", os: "macOS", access: .owned, createdByAgent: true, diskGB: 50, sizeGB: 12))
    #expect(fractions.withLock { $0 } == [0, 0.4, 1])
    #expect(Self.cloneCalls(harness) == ["clone base box"])
    let entries = try harness.registry.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.name == "box")
    #expect(entries.first?.source == "base")
    #expect(entries.first?.client == ToolboxHarness.clientName)
    #expect(entries.first?.fingerprint == VMFingerprint.of(vmNamed: "box", paths: harness.tart.paths))
    let entry = try harness.onlyAuditEntry()
    #expect(entry.vm == "base")
    #expect(entry.outcome == .ok)
  }

  @Test func generatedSandboxNamesFollowTheNameRule() async throws {
    let longSource = String(repeating: "s", count: 60)
    let harness = try Self.harness(sharing: ["base": .template, longSource: .template])
    defer { harness.remove() }
    try harness.tart.addVM("base")
    try harness.tart.addVM(longSource)

    let short = try await harness.toolbox.createSandbox(from: "base")
    let long = try await harness.toolbox.createSandbox(from: longSource)

    #expect(short.name.wholeMatch(of: /base-agent-[0-9a-f]{4}/) != nil)
    #expect(long.name.count == 64)
    #expect(long.name.hasPrefix(String(repeating: "s", count: 53) + "-agent-"))
    #expect(AgentToolbox.isValidVMName(long.name))
  }

  @Test func sandboxNamesMustBeFree() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("base")
    try harness.tart.addVM("private")

    await #expect(throws: AgentToolError.nameTaken("private")) {
      try await harness.toolbox.createSandbox(from: "base", name: "private")
    }
    await #expect(throws: AgentToolError.invalidName("-rf")) {
      try await harness.toolbox.createSandbox(from: "base", name: "-rf")
    }
    #expect(Self.cloneCalls(harness).isEmpty)
    #expect(harness.auditEntries.map(\.outcome) == [.failed, .failed])
  }

  @Test func sandboxesStopAtTheAgentVMLimit() async throws {
    let harness = try Self.harness(maxAgentVMs: 1)
    defer { harness.remove() }
    try harness.tart.addVM("base")
    try harness.tart.addVM("box")
    try harness.registerAgentVM("box")

    await #expect(throws: AgentToolError.tooManyAgentVMs(limit: 1)) {
      try await harness.toolbox.createSandbox(from: "base", name: "box2")
    }
    #expect(Self.cloneCalls(harness).isEmpty)

    // A user VM recreated under the registered name isn't an agent VM, so it doesn't count.
    try FileManager.default.removeItem(at: harness.tart.paths.vmDirectory("box"))
    try harness.tart.addVM("box")
    #expect(try await harness.toolbox.createSandbox(from: "base", name: "box2").name == "box2")
  }

  @Test func sandboxCanStartRightAfterCloning() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("base")

    let summary = try await harness.toolbox.createSandbox(from: "base", name: "box", start: true)

    #expect(summary.state == "running")
    #expect(summary.access == .owned)
    let log = try String(contentsOf: harness.agentPaths.logs.appendingPathComponent("box.log"), encoding: .utf8)
    #expect(log.contains("tart run box --no-graphics ==="))
    #expect(try harness.onlyAuditEntry().outcome == .ok)
  }

  @Test func failedClonesAreNotRegistered() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("base")
    try harness.tart.setFlag("clone-fails")

    let error = await #expect(throws: (any Error).self) {
      try await harness.toolbox.createSandbox(from: "base", name: "box")
    }
    #expect(error?.localizedDescription.contains("no space left on device") == true)
    #expect(try harness.registry.entries().isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  // MARK: Delete

  @Test func agentsCanDeleteOnlyTheirOwnVMs() async throws {
    let harness = try Self.harness(sharing: ["dev": .operate])
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    await #expect(throws: AgentDenial.notOwned(vm: "dev")) { try await harness.toolbox.deleteVM(name: "dev") }
    #expect(harness.tart.calls.isEmpty)
    #expect(FileManager.default.fileExists(atPath: harness.tart.paths.vmDirectory("dev").path))
    #expect(try harness.onlyAuditEntry().outcome == .denied)
  }

  @Test func aUserVMRecreatedUnderAnAgentVMNameCannotBeDeleted() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("box")
    try harness.registerAgentVM("box")
    try FileManager.default.removeItem(at: harness.tart.paths.vmDirectory("box"))
    try harness.tart.addVM("box")

    await #expect(throws: AgentDenial.notOwned(vm: "box")) { try await harness.toolbox.deleteVM(name: "box") }
    #expect(harness.tart.calls.isEmpty)
    #expect(FileManager.default.fileExists(atPath: harness.tart.paths.vmDirectory("box").path))
  }

  @Test func deletingAStoppedAgentVMRemovesItAndItsRegistration() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("box")
    try harness.registerAgentVM("box")

    let result = try await harness.toolbox.deleteVM(name: "box")

    #expect(result == AgentDeleteResult(name: "box", poweredOff: false))
    #expect(harness.tart.calls == ["delete box"])
    #expect(!FileManager.default.fileExists(atPath: harness.tart.paths.vmDirectory("box").path))
    #expect(try harness.registry.entries().isEmpty)
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "delete_vm")
    #expect(entry.outcome == .ok)
  }

  @Test func deletingARunningAgentVMPowersItOffFirst() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("box")
    try harness.registerAgentVM("box")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("box"), ignoringGuestShutdown: true)
    defer { holder.stop() }
    try harness.tart.setFlag("stop-kills", contents: String(holder.pid))

    let result = try await harness.toolbox.deleteVM(name: "box")

    #expect(result == AgentDeleteResult(name: "box", poweredOff: true))
    #expect(harness.tart.calls == ["stop box", "delete box"])
    #expect(try harness.registry.entries().isEmpty)
  }

  @Test func deleteGivesUpWhenTheVMDoesNotStop() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("box")
    try harness.registerAgentVM("box")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("box"), ignoringGuestShutdown: true)
    defer { holder.stop() }

    await #expect(throws: AgentToolError.timedOut(vm: "box", waitingFor: "stop", seconds: 60)) {
      try await harness.toolbox.deleteVM(name: "box")
    }
    #expect(harness.tart.calls == ["stop box"])
    #expect(try harness.registry.entries().map(\.name) == ["box"])
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }
}
