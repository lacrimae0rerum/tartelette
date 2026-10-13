import Foundation
import TarteletteCLI
import TarteletteCore
import TarteletteGuest

/// Whether a running VM's guest agent answers. Returns false instead of throwing.
public typealias AgentGuestReadinessCheck = @Sendable (_ vm: String) async -> Bool

/// The passage of time for the toolbox's waits, injectable so tests don't wait in real time.
public struct AgentClock: Sendable {
  public var now: @Sendable () -> ContinuousClock.Instant
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }

  public static let system = AgentClock(now: { ContinuousClock.now }, sleep: { try await Task.sleep(for: $0) })
}

/// The logic behind the agent tools, independent of MCP.
///
/// Every operation reads the user's agent settings afresh, so changes made in the app apply at
/// once, and refuses everything when they can't be read. It validates the VM names agents pass,
/// checks the operation with `AgentAuthorizer` against the VM's current directory, and records
/// exactly one audit log entry before returning or rethrowing.
public struct AgentToolbox: Sendable {
  public let client: TartClient
  public let agentPaths: AgentPaths
  /// The agent client's name, recorded in the audit log.
  public let clientName: String?
  let guestReadiness: AgentGuestReadinessCheck
  let clock: AgentClock

  /// - Parameter guestReadiness: Defaults to `tartExecReadiness(environment:)` for the client's Tart.
  public init(
    client: TartClient,
    agentPaths: AgentPaths = .standard,
    clientName: String? = nil,
    guestReadiness: AgentGuestReadinessCheck? = nil,
    clock: AgentClock = .system
  ) {
    self.client = client
    self.agentPaths = agentPaths
    self.clientName = clientName
    self.guestReadiness = guestReadiness ?? Self.tartExecReadiness(environment: client.environment)
    self.clock = clock
  }

  /// A toolbox for the installed Tart, found as `TartEnvironment.detect` finds it.
  ///
  /// - Throws: `AgentToolError.tartNotFound` when no `tart` executable can be found.
  public static func detect(
    preferredExecutablePath: String? = nil,
    tartHome: String? = nil,
    agentPaths: AgentPaths = .standard,
    clientName: String? = nil
  ) throws -> AgentToolbox {
    guard let environment = TartEnvironment.detect(preferredExecutablePath: preferredExecutablePath, tartHome: tartHome)
    else { throw AgentToolError.tartNotFound }
    return AgentToolbox(client: TartClient(environment: environment), agentPaths: agentPaths, clientName: clientName)
  }

  /// Tart's home directory, the one the client's `tart` uses.
  public var tartPaths: TartPaths { client.environment.paths }

  /// Runs `true` in the guest through `tart exec` and reports whether it exited 0 within five seconds.
  public static func tartExecReadiness(
    environment: TartEnvironment,
    runner: any ProcessRunning = ProcessRunner()
  ) -> AgentGuestReadinessCheck {
    { name in
      let transport = TartExecTransport(
        vmName: name, tartExecutable: environment.executable, environment: environment.variables(forRun: false),
        runner: runner)
      let output = try? await transport.run(["true"], timeout: .seconds(5))
      return output?.succeeded == true
    }
  }

  /// Whether agents may use `name`: 1 to 64 ASCII letters, digits, `.`, `_` or `-`, starting with a
  /// letter or digit. This also keeps names `tart` would parse as options, or paths, out of argv.
  public static func isValidVMName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard (1...64).contains(bytes.count) else { return false }
    func isAlphanumeric(_ byte: UInt8) -> Bool {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
    let punctuation: Set<UInt8> = [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")]
    return isAlphanumeric(bytes[0]) && bytes.dropFirst().allSatisfy { isAlphanumeric($0) || punctuation.contains($0) }
  }
}

/// The user's settings and the agent VM registry, read at the start of one tool call.
struct AgentCallContext {
  let policy: AgentPolicy
  let entries: [AgentVMEntry]
  let authorizer: AgentAuthorizer
}

extension AgentToolbox {
  var registry: AgentVMRegistry { AgentVMRegistry(paths: agentPaths) }

  /// Runs one tool call: loads the settings and registry, runs `body`, and records one audit entry
  /// (`denied` for an `AgentDenial`, `failed` for any other error) before returning or rethrowing.
  ///
  /// - Parameter body: Returns the call's value and a short detail for the audit log.
  func perform<Value>(
    _ tool: AgentTool,
    vm: String?,
    _ body: (AgentCallContext) async throws -> (value: Value, detail: String)
  ) async throws -> Value {
    do {
      let result = try await body(try loadContext())
      record(tool, vm: vm, outcome: .ok, detail: result.detail)
      return result.value
    } catch {
      record(tool, vm: vm, outcome: error is AgentDenial ? .denied : .failed, detail: error.localizedDescription)
      throw error
    }
  }

  /// The current settings and registry. Agents are refused everything while they are off or the
  /// settings can't be read.
  func loadContext() throws -> AgentCallContext {
    let policy: AgentPolicy
    do {
      policy = try AgentPolicyStore(file: agentPaths.policyFile).load()
    } catch {
      throw AgentToolError.settingsUnreadable(detail: error.localizedDescription)
    }
    guard policy.enabled else { throw AgentDenial.agentsDisabled }
    let entries = try registry.entries()
    return AgentCallContext(policy: policy, entries: entries, authorizer: AgentAuthorizer(policy: policy, registry: entries))
  }

  /// Validates a VM name given by an agent and checks `operation` against the VM's current directory.
  ///
  /// - Returns: The VM directory's fingerprint, nil when there is no such directory.
  @discardableResult
  func authorize(_ operation: AgentOperation, vm name: String, in context: AgentCallContext) throws -> String? {
    guard Self.isValidVMName(name) else { throw AgentToolError.invalidName(name) }
    let fingerprint = VMFingerprint.of(vmNamed: name, paths: tartPaths)
    try context.authorizer.check(operation, vm: name, fingerprint: fingerprint)
    return fingerprint
  }

  /// Local VMs only: `tart list` can also report images in the OCI cache, which agents can't use.
  func localVMs() async throws -> [VMListing] {
    try await client.list(source: .local).filter { $0.source == .local }
  }

  func localVM(named name: String) async throws -> VMListing {
    guard let vm = try await localVMs().first(where: { $0.name == name }) else {
      throw AgentToolError.vmNotFound(name)
    }
    return vm
  }

  func summary(of vm: VMListing, configuration: VMConfigFile?, access: EffectiveAccess) -> AgentVMSummary {
    AgentVMSummary(
      name: vm.name,
      state: vm.state.rawValue,
      os: (configuration?.operatingSystem ?? .unknown).displayName,
      access: access,
      createdByAgent: access == .owned,
      diskGB: vm.diskGB,
      sizeGB: vm.sizeGB)
  }

  /// The call has already happened (or been refused) when it is recorded, so a log that can't be
  /// written doesn't change its result.
  private func record(_ tool: AgentTool, vm: String?, outcome: AgentAuditEntry.Outcome, detail: String) {
    let entry = AgentAuditEntry(
      client: clientName, tool: tool.rawValue, vm: vm.map { String($0.prefix(128)) }, outcome: outcome, detail: detail)
    try? AgentAuditLog(file: agentPaths.auditLogFile).record(entry)
  }
}
