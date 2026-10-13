import Foundation
import TarteletteCLI
import TarteletteCore

/// What `delete_vm` reports.
public struct AgentDeleteResult: Codable, Sendable, Equatable {
  public var name: String
  /// The VM was running and had to be powered off first.
  public var poweredOff: Bool

  public init(name: String, poweredOff: Bool) {
    self.name = name
    self.poweredOff = poweredOff
  }
}

extension AgentToolbox {
  /// How long `deleteVM` waits for a running VM to stop after powering it off.
  public static let deleteStopTimeoutSeconds = 60

  /// `create_sandbox` (cloneFrom on the source): clones a stopped VM shared as Template into a new
  /// VM owned by agents, optionally starting it.
  ///
  /// - Parameters:
  ///   - name: The new VM's name; defaults to `<source>-agent-<4 hex digits>`.
  ///   - start: Start the new VM (headless, without waiting for its guest agent).
  ///   - progress: Receives the clone's progress in 0...1.
  /// - Returns: The new VM's summary.
  public func createSandbox(
    from source: String,
    name: String? = nil,
    start: Bool = false,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> AgentVMSummary {
    try await perform(.createSandbox, vm: source) { context in
      try authorize(.cloneFrom, vm: source, in: context)
      if let name, !Self.isValidVMName(name) { throw AgentToolError.invalidName(name) }
      let vms = try await localVMs()
      guard let sourceVM = vms.first(where: { $0.name == source }) else { throw AgentToolError.vmNotFound(source) }
      guard sourceVM.state == .stopped else { throw AgentToolError.sourceNotStopped(source) }
      let agentVMs = context.entries.filter { VMFingerprint.of(vmNamed: $0.name, paths: tartPaths) == $0.fingerprint }
      let limit = context.policy.limits.maxAgentVMs
      guard agentVMs.count < limit else { throw AgentToolError.tooManyAgentVMs(limit: limit) }

      let taken = Set(vms.map(\.name))
      let isFree = { (candidate: String) in
        !taken.contains(candidate) && VMFingerprint.of(vmNamed: candidate, paths: tartPaths) == nil
      }
      let newName = name ?? Self.sandboxName(from: source, isFree: isFree)
      guard isFree(newName) else { throw AgentToolError.nameTaken(newName) }

      try await clone(source, as: newName, progress: progress)
      guard let fingerprint = VMFingerprint.of(vmNamed: newName, paths: tartPaths) else {
        throw AgentToolError.unidentifiedVM(newName)
      }
      try registry.register(
        AgentVMEntry(name: newName, source: source, client: clientName, createdAt: Date(), fingerprint: fingerprint))

      // Read again: the authorizer now sees the new VM as owned.
      let updated = try loadContext()
      var started: AgentStartResult?
      if start {
        try authorize(.start, vm: newName, in: updated)
        started = try await self.start(newName, wait: false, timeoutSeconds: Self.defaultStartTimeoutSeconds)
      }
      var created = summary(
        of: try await localVM(named: newName), configuration: try? client.configuration(of: newName),
        access: updated.authorizer.effectiveAccess(for: newName, fingerprint: fingerprint))
      // `tart list` may not report a VM launched a moment ago as running yet.
      if let started { created.state = started.state }
      return (created, "created “\(newName)”" + (started == nil ? "" : " and started it"))
    }
  }

  /// `delete_vm` (delete, owned VMs only): powers the VM off if it is running, deletes it and
  /// forgets it in the agent VM registry.
  public func deleteVM(name: String) async throws -> AgentDeleteResult {
    try await perform(.deleteVM, vm: name) { context in
      try authorize(.delete, vm: name, in: context)
      let wasRunning = isRunning(name)
      if wasRunning {
        try await powerOff(name)
        guard try await waitUntilStopped(name, timeout: .seconds(Self.deleteStopTimeoutSeconds)) else {
          throw AgentToolError.timedOut(vm: name, waitingFor: "stop", seconds: Self.deleteStopTimeoutSeconds)
        }
      }
      try await client.execute(.delete(names: [name]), timeout: .seconds(120))
      // The VM is gone; an entry left behind is dropped by the next listing.
      try? registry.unregister(name: name)
      return (AgentDeleteResult(name: name, poweredOff: wasRunning), wasRunning ? "powered off and deleted" : "deleted")
    }
  }

  /// `<source>-agent-<4 random hex digits>`, with the source shortened so the name stays within
  /// 64 characters (a valid source keeps it valid). Tries a few suffixes and returns the first
  /// free name, or the last one tried.
  static func sandboxName(from source: String, isFree: (String) -> Bool) -> String {
    var candidate = ""
    for _ in 0..<8 {
      let suffix = "-agent-" + String(format: "%04x", UInt16.random(in: .min ... .max))
      candidate = source.prefix(64 - suffix.count) + suffix
      if isFree(candidate) { break }
    }
    return candidate
  }

  /// Runs `tart clone`, forwarding its progress; cancelling the task cancels the clone.
  private func clone(_ source: String, as newName: String, progress: (@Sendable (Double) -> Void)?) async throws {
    let operation = client.stream(.clone(CloneOptions(source: source, newName: newName)))
    try await withTaskCancellationHandler {
      for await event in operation.events {
        switch event {
        case .progress(let fraction):
          progress?(fraction)
        case .finished(let exitCode, let message) where exitCode != 0:
          throw TartError(command: operation.command.commandLine, exitCode: exitCode, message: message ?? "")
        default:
          break
        }
      }
    } onCancel: {
      operation.cancel()
    }
  }
}
