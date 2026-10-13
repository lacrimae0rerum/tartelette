import Foundation
import TarteletteCore
import Testing

@testable import TarteletteAgents

// Serialized: these tests spawn many short processes, and running them all at once slows the
// process-based tests elsewhere enough to trip their real-time timeouts.
@Suite("Agent toolbox: running commands in guests", .serialized)
struct AgentToolboxExecTests {
  private static func harness(
    sharing vms: [String: AgentAccess] = ["dev": .operate],
    limits: AgentLimits = AgentLimits()
  ) throws -> ToolboxHarness {
    try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: vms, limits: limits))
  }

  // MARK: Running commands

  @Test func execRunsTheCommandInALoginShellWithTheGuestsLocale() async throws {
    let harness = try Self.harness(sharing: ["mac": .operate, "ubuntu": .operate])
    defer { harness.remove() }
    try harness.tart.addVM("mac", state: "running")
    try harness.tart.addVM("ubuntu", os: "linux", state: "running")
    let guest = ScriptedTransport(status: 0, stdout: "hi\n")
    let toolbox = harness.toolbox(guest: guest)

    let result = try await toolbox.exec(name: "mac", command: "echo hi")
    _ = try await toolbox.exec(name: "ubuntu", command: "uname -a | head -1")

    #expect(
      result
        == AgentExecResult(
          exitCode: 0, stdout: "hi\n", stderr: "", stdoutTruncated: false, stderrTruncated: false, stdoutBytes: 3,
          stderrBytes: 0))
    #expect(
      guest.calls.map(\.command) == [
        ["/usr/bin/env", "LANG=en_US.UTF-8", "/bin/sh", "-lc", "echo hi"],
        ["/usr/bin/env", "LANG=C.UTF-8", "/bin/sh", "-lc", "uname -a | head -1"],
      ])
    #expect(guest.calls.allSatisfy { $0.standardInput == nil })
  }

  @Test func execPassesStandardInputAndReportsAFailingExitCode() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 3, stdout: "partial", stderr: "grep: nothing matched\n")

    let result = try await harness.toolbox(guest: guest).exec(name: "dev", command: "grep x", standardInput: "line 1\nline 2\n")

    #expect(result.exitCode == 3)
    #expect(result.stdout == "partial")
    #expect(result.stderr == "grep: nothing matched\n")
    #expect(guest.calls.map(\.standardInput) == [Data("line 1\nline 2\n".utf8)])
    // A command that fails still ran: the call succeeded.
    #expect(try harness.onlyAuditEntry().outcome == .ok)
  }

  @Test func execCutsLongOutputOnACharacterBoundary() async throws {
    let harness = try Self.harness(limits: AgentLimits(maxOutputBytes: 7))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    // "café€uro": é is 2 bytes and € is 3 (bytes 5 to 7), so a cut after 7 bytes falls inside "€".
    let guest = ScriptedTransport(status: 0, stdout: "caf\u{e9}\u{20ac}uro", stderr: "12345678")

    let result = try await harness.toolbox(guest: guest).exec(name: "dev", command: "cat menu")

    #expect(
      result
        == AgentExecResult(
          exitCode: 0, stdout: "caf\u{e9}", stderr: "1234567", stdoutTruncated: true, stderrTruncated: true,
          stdoutBytes: 11, stderrBytes: 8))
  }

  @Test func execDecodesInvalidUTF8Leniently() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport { _ in CommandOutput(status: 0, stdout: Data([0x61, 0xFF, 0x62])) }

    let result = try await harness.toolbox(guest: guest).exec(name: "dev", command: "cat blob")

    #expect(result.stdout == "a\u{FFFD}b")
    #expect(result.stdoutBytes == 3)
    #expect(!result.stdoutTruncated)
  }

  @Test func execTimeoutDefaultsToAndIsCappedByTheLimits() async throws {
    let harness = try Self.harness(limits: AgentLimits(execTimeoutDefaultSeconds: 30, execTimeoutMaxSeconds: 90))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 0)
    let toolbox = harness.toolbox(guest: guest)

    for timeout in [nil, 0, -5, 45, 90, 3600] {
      _ = try await toolbox.exec(name: "dev", command: "sleep 1", timeout: timeout)
    }

    let seconds: [Duration] = [30, 30, 30, 45, 90, 90].map { .seconds($0) }
    #expect(guest.calls.map(\.timeout) == seconds)
  }

  // MARK: Failures

  @Test func execReportsATimeout() async throws {
    let harness = try Self.harness(limits: AgentLimits(execTimeoutDefaultSeconds: 30))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport { call in throw ProcessRunError.timedOut(after: call.timeout ?? .zero) }

    await #expect(throws: AgentToolError.commandTimedOut(vm: "dev", seconds: 30)) {
      try await harness.toolbox(guest: guest).exec(name: "dev", command: "sleep 100")
    }
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test func execExplainsAGuestAgentThatDoesNotAnswer() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(
      status: 1,
      stderr: "Error: Failed to connect to the VM using its control socket: unavailable, is the Tart Guest Agent running?\n")

    let error = await #expect(throws: AgentToolError.guestAgentUnreachable("dev")) {
      try await harness.toolbox(guest: guest).exec(name: "dev", command: "id")
    }
    #expect(error?.localizedDescription.contains("The Tart Guest Agent in “dev” isn't answering") == true)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test func execNoticesAVMThatStoppedMeanwhile() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 2, stderr: "Error: VM \"dev\" is not running\n")

    await #expect(throws: AgentToolError.vmNotRunning("dev")) {
      try await harness.toolbox(guest: guest).exec(name: "dev", command: "id")
    }
  }

  @Test(arguments: [
    ("inactive\n", "Error: the guest agent isn't loaded\n"),
    ("", "launchctl: tart guest agent not loaded\n"),
  ])
  func aCommandMentioningTheGuestAgentIsNotMistakenForAnUnreachableOne(stdout: String, stderr: String) async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 1, stdout: stdout, stderr: stderr)

    let result = try await harness.toolbox(guest: guest).exec(name: "dev", command: "launchctl print tart-guest-agent")

    #expect(result.exitCode == 1)
    #expect(result.stdout == stdout)
    #expect(result.stderr == stderr)
  }

  @Test func execGoesThroughTartExecByDefault() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    try harness.tart.setFlag("agent-answers")

    let result = try await harness.toolbox.exec(name: "dev", command: "uname -s", standardInput: "x")

    #expect(result.exitCode == 0)
    #expect(harness.tart.calls.last == "exec -i dev /usr/bin/env LANG=en_US.UTF-8 /bin/sh -lc uname -s")

    // The fake `tart exec` fails the way the real one does when the guest agent doesn't answer.
    try harness.tart.setFlag("agent-answers", contents: nil)
    await #expect(throws: AgentToolError.guestAgentUnreachable("dev")) {
      try await harness.toolbox.exec(name: "dev", command: "uname -s")
    }
  }

  // MARK: Audit

  @Test func execRecordsTheExitCodeAndCommandButNeverStandardInput() async throws {
    let harness = try Self.harness(limits: AgentLimits(execTimeoutDefaultSeconds: 5))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let secret = "hunter2-very-secret"
    let guest = ScriptedTransport { call in
      guard call.command.last == "login" else { throw ProcessRunError.timedOut(after: .seconds(5)) }
      return CommandOutput(status: 0, stdout: Data("ok \(secret)\n".utf8))
    }
    let toolbox = harness.toolbox(guest: guest)

    _ = try await toolbox.exec(name: "dev", command: "login", standardInput: secret)
    await #expect(throws: AgentToolError.self) {
      try await toolbox.exec(name: "dev", command: "slow-login", standardInput: secret)
    }

    let entries = harness.auditEntries
    #expect(entries.map(\.tool) == ["exec", "exec"])
    #expect(entries.map(\.outcome) == [.ok, .failed])
    #expect(entries.first?.detail == "exit 0: login")
    #expect(!harness.auditLogText.contains(secret))
  }

  // MARK: Refusals

  @Test func execNeedsOperateAccess() async throws {
    let harness = try Self.harness(sharing: ["dev": .read])
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 0)

    await #expect(throws: AgentDenial.notPermitted(vm: "dev", operation: .exec, access: .read)) {
      try await harness.toolbox(guest: guest).exec(name: "dev", command: "id")
    }
    #expect(guest.calls.isEmpty)
    #expect(harness.tart.calls.isEmpty)
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "exec")
    #expect(entry.vm == "dev")
    #expect(entry.outcome == .denied)
  }

  @Test func execIsRefusedWhileAgentsAreOff() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: false, vms: ["dev": .operate]))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 0)

    await #expect(throws: AgentDenial.agentsDisabled) {
      try await harness.toolbox(guest: guest).exec(name: "dev", command: "id")
    }
    #expect(guest.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .denied)
  }

  @Test func execNeedsARunningVM() async throws {
    let harness = try Self.harness(sharing: ["dev": .operate, "gone": .operate])
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    let guest = ScriptedTransport(status: 0)
    let toolbox = harness.toolbox(guest: guest)

    let error = await #expect(throws: AgentToolError.vmNotRunning("dev")) {
      try await toolbox.exec(name: "dev", command: "id")
    }
    #expect(error?.localizedDescription == "VM “dev” isn't running. Start it with start_vm.")
    await #expect(throws: AgentToolError.vmNotFound("gone")) {
      try await toolbox.exec(name: "gone", command: "id")
    }
    #expect(guest.calls.isEmpty)
    #expect(harness.auditEntries.map(\.outcome) == [.failed, .failed])
  }

  @Test(arguments: ["", "  \n", "echo a\u{0}b"])
  func execRefusesEmptyCommandsAndNULs(command: String) async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = ScriptedTransport(status: 0)

    await #expect(throws: AgentToolError.invalidCommand) {
      try await harness.toolbox(guest: guest).exec(name: "dev", command: command)
    }
    #expect(guest.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }
}
