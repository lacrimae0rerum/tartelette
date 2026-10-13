import Foundation
import TarteletteCore
import TarteletteGuest
import Testing

@testable import TarteletteAgents

@Suite("Agent toolbox: starting and stopping VMs")
struct AgentToolboxPowerTests {
  private static let loginwindowShutdown = [
    "/usr/bin/osascript", "-e", "tell application \"loginwindow\" to «event aevtshut»",
  ]

  /// - Parameter realPause: Real time per virtual sleep; longer where a child process must exit
  ///   between polls, so the test holds on a loaded machine.
  private static func harness(
    sharing vms: [String: AgentAccess] = ["dev": .operate],
    realPause: Duration = .milliseconds(10)
  ) throws -> ToolboxHarness {
    try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: vms), realPause: realPause)
  }

  private static func log(_ harness: ToolboxHarness, _ name: String) -> String? {
    try? String(contentsOf: harness.agentPaths.logs.appendingPathComponent("\(name).log"), encoding: .utf8)
  }

  // MARK: Start

  @Test func startLaunchesHeadlessAndLogsWhereTheAppLooks() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    let result = try await harness.toolbox.startVM(name: "dev")

    #expect(result == AgentStartResult(name: "dev", state: "running", alreadyRunning: false, guestAgentReady: nil))
    // The launch header is written before `tart run` starts, so it shows the exact argv.
    #expect(Self.log(harness, "dev")?.contains("tart run dev --no-graphics ===") == true)
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "start_vm")
    #expect(entry.vm == "dev")
    #expect(entry.outcome == .ok)
  }

  @Test func startingARunningVMLaunchesNothing() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    harness.guest.answer(fromCheck: 1)

    let result = try await harness.toolbox.startVM(name: "dev", wait: true)

    #expect(result == AgentStartResult(name: "dev", state: "running", alreadyRunning: true, guestAgentReady: true))
    #expect(Self.log(harness, "dev") == nil)
    #expect(try harness.onlyAuditEntry().outcome == .ok)
  }

  @Test func startHonoursTheMacOSGuestLimit() async throws {
    let harness = try Self.harness(sharing: ["dev": .operate, "ubuntu": .operate])
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    try harness.tart.addVM("ubuntu", os: "linux")
    try harness.tart.addVM("mac1", state: "running")
    try harness.tart.addVM("mac2", state: "running")

    await #expect(throws: AgentToolError.macOSGuestLimitReached(vm: "dev")) {
      try await harness.toolbox.startVM(name: "dev")
    }
    #expect(Self.log(harness, "dev") == nil)
    // Linux guests don't count against the limit.
    #expect(try await harness.toolbox.startVM(name: "ubuntu").state == "running")
    #expect(harness.auditEntries.map(\.outcome) == [.failed, .ok])
  }

  @Test func startWaitsUntilTheGuestAgentAnswers() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    harness.guest.answer(fromCheck: 3)

    let result = try await harness.toolbox.startVM(name: "dev", wait: true)

    #expect(result == AgentStartResult(name: "dev", state: "running", alreadyRunning: false, guestAgentReady: true))
    #expect(harness.guest.checks == 3)
    #expect(harness.clock.sleeps == [.seconds(2), .seconds(2)])
  }

  @Test func startStopsWaitingAtTheTimeout() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    let result = try await harness.toolbox.startVM(name: "dev", wait: true, timeout: 10)

    #expect(result == AgentStartResult(name: "dev", state: "running", alreadyRunning: false, guestAgentReady: false))
    #expect(harness.clock.elapsed >= .seconds(10))
    #expect(harness.clock.elapsed <= .seconds(12))
    #expect(try harness.onlyAuditEntry().outcome == .ok)
  }

  @Test func startReportsTheLogWhenTartExitsEarly() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    try harness.tart.setFlag("run-fails")

    let error = await #expect(throws: AgentToolError.self) {
      try await harness.toolbox.startVM(name: "dev", wait: true)
    }
    guard case .startFailed(let name, let logTail) = error else {
      Issue.record("unexpected \(String(describing: error))")
      return
    }
    #expect(name == "dev")
    #expect(logTail.contains("Error: the virtual machine failed to start"))
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test func startNeedsOperateAccess() async throws {
    let harness = try Self.harness(sharing: ["dev": .read])
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    await #expect(throws: AgentDenial.notPermitted(vm: "dev", operation: .start, access: .read)) {
      try await harness.toolbox.startVM(name: "dev")
    }
    #expect(harness.tart.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .denied)
  }

  // MARK: Stop

  @Test func stoppingAStoppedVMDoesNothing() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev")

    let result = try await harness.toolbox.stopVM(name: "dev")

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .alreadyStopped))
    #expect(harness.tart.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .ok)
  }

  @Test func stopAsksTheGuestToShutDownFirst() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"))
    defer { holder.stop() }

    let result = try await harness.toolbox.stopVM(name: "dev")

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .guestShutdown))
    #expect(!harness.tart.calls.contains { $0.hasPrefix("stop") })
  }

  @Test func stopPowersOffAGuestThatDoesNotShutDown() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"), ignoringGuestShutdown: true)
    defer { holder.stop() }

    let result = try await harness.toolbox.stopVM(name: "dev", timeout: 5)

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .powerOff))
    // The fake guest agent doesn't answer, so the in-guest request goes nowhere and SIGUSR2 follows.
    #expect(harness.tart.calls == ["exec dev \(Self.loginwindowShutdown.joined(separator: " "))", "stop dev"])
    #expect(harness.clock.elapsed >= .seconds(5))
    let entry = try harness.onlyAuditEntry()
    #expect(entry.outcome == .ok)
    #expect(entry.detail == "powerOff after SIGUSR2")
  }

  @Test func forcedStopPowersOffAtOnce() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"))
    defer { holder.stop() }
    let guest = ScriptedTransport(status: 0)

    let result = try await harness.toolbox(guest: guest).stopVM(name: "dev", force: true)

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .powerOff))
    #expect(harness.tart.calls == ["stop dev"])
    // No SIGUSR2 reached the holder, which would have made it exit, and the guest wasn't asked.
    #expect(holder.isRunning)
    #expect(guest.calls.isEmpty)
    #expect(harness.clock.sleeps.isEmpty)
    #expect(try harness.onlyAuditEntry().detail == "powerOff")
  }

  // MARK: Stop: macOS guests are asked from the inside

  @Test func stopAsksAMacOSGuestToShutDownFromInside() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    // Ignores SIGUSR2, like a headless macOS guest; only the in-guest request stops it.
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"), ignoringGuestShutdown: true)
    defer { holder.stop() }
    let guest = ScriptedTransport { _ in
      holder.stop()
      return CommandOutput(status: 0)
    }

    let result = try await harness.toolbox(guest: guest).stopVM(name: "dev")

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .guestShutdown))
    #expect(guest.calls.map(\.command) == [Self.loginwindowShutdown])
    #expect(guest.calls.map(\.timeout) == [.seconds(15)])
    #expect(harness.tart.calls.isEmpty)
    let entry = try harness.onlyAuditEntry()
    #expect(entry.outcome == .ok)
    #expect(entry.detail == "guestShutdown after an in-guest shutdown request")
  }

  @Test func aDeliveredInGuestRequestIsNotFollowedBySIGUSR2() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    // Would exit on SIGUSR2.
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"))
    defer { holder.stop() }
    let guest = ScriptedTransport(status: 0)

    let result = try await harness.toolbox(guest: guest).stopVM(name: "dev", timeout: 3)

    // The guest accepted the request but never stopped, so it was powered off at the timeout.
    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .powerOff))
    #expect(holder.isRunning)
    #expect(harness.tart.calls == ["stop dev"])
    #expect(harness.clock.elapsed >= .seconds(3))
    #expect(try harness.onlyAuditEntry().detail == "powerOff after an in-guest shutdown request")
  }

  @Test func stopFallsBackToSIGUSR2WhenTheGuestAgentIsUnreachable() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"))
    defer { holder.stop() }
    let guest = ScriptedTransport { _ in throw GuestTransportError.unreachable("The guest agent is not running.") }

    let result = try await harness.toolbox(guest: guest).stopVM(name: "dev")

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .guestShutdown))
    #expect(guest.calls.count == 1)
    // The stop returned once the lock was gone; the holder's exit is noticed a little later.
    #expect(await holder.waitForExit())
    #expect(holder.exitSignal == SIGUSR2)
    #expect(harness.tart.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().detail == "guestShutdown after SIGUSR2")
  }

  @Test func linuxGuestsGetSIGUSR2AndNoInGuestRequest() async throws {
    let harness = try Self.harness(realPause: .milliseconds(100))
    defer { harness.remove() }
    try harness.tart.addVM("dev", os: "linux")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"))
    defer { holder.stop() }
    let guest = ScriptedTransport(status: 0)

    let result = try await harness.toolbox(guest: guest).stopVM(name: "dev")

    #expect(result == AgentStopResult(name: "dev", state: "stopped", method: .guestShutdown))
    #expect(guest.calls.isEmpty)
    // The stop returned once the lock was gone; the holder's exit is noticed a little later.
    #expect(await holder.waitForExit())
    #expect(holder.exitSignal == SIGUSR2)
    #expect(harness.tart.calls.isEmpty)
  }

  @Test func stopNeedsOperateAccess() async throws {
    let harness = try Self.harness(sharing: ["dev": .template])
    defer { harness.remove() }
    try harness.tart.addVM("dev")
    let holder = try FcntlLockHolder(file: harness.tart.paths.configFile("dev"))
    defer { holder.stop() }

    await #expect(throws: AgentDenial.notPermitted(vm: "dev", operation: .stop, access: .template)) {
      try await harness.toolbox.stopVM(name: "dev", force: true)
    }
    #expect(holder.isRunning)
    #expect(harness.tart.calls.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .denied)
  }
}
