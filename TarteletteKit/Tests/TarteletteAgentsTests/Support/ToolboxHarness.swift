import Foundation
import TarteletteGuest
import Testing
import os

@testable import TarteletteAgents

/// Virtual time for the toolbox: `sleep` advances it at once, after a short real pause so child
/// processes (a fake `tart run`, a lock holder) get the chance to change state between polls.
final class ManualClock: Sendable {
  private struct State {
    var elapsed: Duration = .zero
    var sleeps: [Duration] = []
  }

  private let origin = ContinuousClock.now
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let realPause: Duration

  init(realPause: Duration = .milliseconds(10)) {
    self.realPause = realPause
  }

  /// Virtual time slept so far.
  var elapsed: Duration { state.withLock { $0.elapsed } }
  /// Every requested sleep, in order.
  var sleeps: [Duration] { state.withLock { $0.sleeps } }

  var clock: AgentClock {
    AgentClock(
      now: { [origin, state] in origin + state.withLock { $0.elapsed } },
      sleep: { [state, realPause] duration in
        state.withLock {
          $0.elapsed += duration
          $0.sleeps.append(duration)
        }
        try await Task.sleep(for: realPause)
      })
  }
}

/// A guest agent that starts answering at a given readiness check, or never.
final class FakeGuestAgent: Sendable {
  private struct State {
    var checks = 0
    var answersFromCheck: Int?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Readiness checks made so far.
  var checks: Int { state.withLock { $0.checks } }

  /// Makes the agent answer from the `check`-th readiness check on; nil means never.
  func answer(fromCheck check: Int?) {
    state.withLock { $0.answersFromCheck = check }
  }

  var readiness: AgentGuestReadinessCheck {
    { [state] _ in
      state.withLock { state in
        state.checks += 1
        guard let first = state.answersFromCheck else { return false }
        return state.checks >= first
      }
    }
  }
}

/// A fake `tart` with a temporary Tart home, temporary agent paths, virtual time and a fake guest
/// agent, wired into an `AgentToolbox`.
struct ToolboxHarness {
  static let clientName = "test-agent"

  let directory: TemporaryDirectory
  let tart: FakeTart
  let agentPaths: AgentPaths
  let clock: ManualClock
  let guest = FakeGuestAgent()

  /// - Parameter policy: Saved as `agents.json`; nil leaves the file missing.
  init(policy: AgentPolicy? = AgentPolicy(enabled: true), realPause: Duration = .milliseconds(10)) throws {
    directory = try TemporaryDirectory()
    tart = try FakeTart(in: directory.url)
    agentPaths = AgentPaths(applicationSupport: directory.file("support"), logs: directory.file("logs"))
    clock = ManualClock(realPause: realPause)
    if let policy { try savePolicy(policy) }
  }

  var toolbox: AgentToolbox {
    AgentToolbox(
      client: tart.client, agentPaths: agentPaths, clientName: Self.clientName,
      guestReadiness: guest.readiness, clock: clock.clock)
  }

  /// The toolbox, reaching every guest through `transport` instead of `tart exec`.
  func toolbox(guest transport: any GuestTransport) -> AgentToolbox {
    AgentToolbox(
      client: tart.client, agentPaths: agentPaths, clientName: Self.clientName,
      guestReadiness: guest.readiness, guestTransport: { _ in transport }, clock: clock.clock)
  }

  /// The audit log file's raw contents.
  var auditLogText: String {
    (try? String(contentsOf: agentPaths.auditLogFile, encoding: .utf8)) ?? ""
  }

  func savePolicy(_ policy: AgentPolicy) throws {
    try AgentPolicyStore(file: agentPaths.policyFile).save(policy)
  }

  var registry: AgentVMRegistry { AgentVMRegistry(paths: agentPaths) }

  /// Registers an existing VM as created by an agent, with its current fingerprint.
  func registerAgentVM(_ name: String, source: String = "base") throws {
    let fingerprint = try #require(VMFingerprint.of(vmNamed: name, paths: tart.paths))
    try registry.register(
      AgentVMEntry(name: name, source: source, client: Self.clientName, createdAt: Date(), fingerprint: fingerprint))
  }

  var auditEntries: [AgentAuditEntry] {
    AgentAuditLog(file: agentPaths.auditLogFile).recent(limit: 1000)
  }

  /// The audit log holds exactly one entry; returns it.
  func onlyAuditEntry(sourceLocation: SourceLocation = #_sourceLocation) throws -> AgentAuditEntry {
    let entries = auditEntries
    try #require(entries.count == 1, "expected one audit entry, found \(entries.count)", sourceLocation: sourceLocation)
    return entries[0]
  }

  func remove() {
    tart.killLaunchedVMs()
    directory.remove()
  }
}
