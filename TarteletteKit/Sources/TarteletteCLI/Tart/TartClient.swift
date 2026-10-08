import Foundation
import TarteletteCore

/// Drives the `tart` executable: one-shot commands, streaming operations and VM processes.
///
/// Every method is safe to call from any task. Commands that fail throw `TartError` with Tart's
/// own (cleaned) diagnostic, so it can be shown to the user as is.
public final class TartClient: Sendable {
  public let environment: TartEnvironment
  private let runner: any ProcessRunning
  private let capabilityCache = Locked<TartCapabilities?>(nil)

  public init(environment: TartEnvironment, runner: any ProcessRunning = ProcessRunner()) {
    self.environment = environment
    self.runner = runner
  }

  // MARK: - One-shot commands

  /// Runs `command` to completion.
  ///
  /// - Throws: `TartError` when Tart exits with a non-zero code; `ProcessRunError` when the process
  ///   could not be launched, timed out or the task was cancelled.
  @discardableResult
  public func execute(_ command: TartCommand, standardInput: Data? = nil, timeout: Duration? = nil) async throws
    -> CommandOutput
  {
    let isRun = if case .run = command { true } else { false }
    let request = ProcessRequest(
      executable: environment.executable,
      arguments: command.arguments,
      environment: environment.variables(forRun: isRun),
      standardInput: standardInput,
      timeout: timeout
    )
    let output = try await runner.run(request)
    guard output.succeeded else {
      throw TartError(
        command: command.commandLine,
        exitCode: output.status,
        message: TartError.cleanMessage(output.diagnostic)
      )
    }
    return output
  }

  /// `tart list --format json`. Doesn't touch VMs' access dates, so it is the right call for polling.
  public func list(source: VMSource? = nil) async throws -> [VMListing] {
    let output = try await execute(.list(ListOptions(source: source, format: .json)), timeout: .seconds(30))
    return try TartOutputParsing.parseList(output.stdout)
  }

  /// `tart get <name> --format json`.
  ///
  /// Note: Tart updates the VM's last-accessed date on every `get`, which influences
  /// `prune --entries vms`; prefer `list` and `configuration(of:)` for frequent refreshes.
  public func details(of name: String) async throws -> VMDetails {
    let output = try await execute(.get(name: name, format: .json), timeout: .seconds(30))
    return try TartOutputParsing.parseDetails(output.stdout)
  }

  /// Reads the VM's `config.json` directly (MAC address, minimum CPU/memory, display unit and
  /// refit flag — fields `tart get` doesn't expose). Doesn't spawn Tart or bump the access date.
  public func configuration(of name: String) throws -> VMConfigFile {
    let data = try Data(contentsOf: environment.paths.configFile(name))
    return try TartOutputParsing.parseConfig(data)
  }

  /// `tart ip`. Waits up to `options.waitSeconds` for the guest to obtain an address.
  public func ipAddress(_ options: IPOptions) async throws -> String {
    let timeout = Duration.seconds(Double(options.waitSeconds ?? 0) + 15)
    let command = TartCommand.ip(options)
    let output = try await execute(command, timeout: timeout)
    guard let address = TartOutputParsing.parseIP(output.stdoutString) else {
      throw TartError(command: command.commandLine, exitCode: TartExitCode.failure, message: "No IP address found.")
    }
    return address
  }

  /// The installed Tart version, e.g. `2.40.1` (`SNAPSHOT` for source builds).
  public func version() async throws -> String {
    let output = try await execute(.version, timeout: .seconds(15))
    return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `tart login --username … --password-stdin`; the password is written to stdin, never argv.
  public func login(_ options: LoginOptions, password: String) async throws {
    try await execute(.login(options), standardInput: Data(password.utf8), timeout: .seconds(120))
  }

  // MARK: - Long-running work

  /// Starts `command` and streams its output and progress. See `TartOperation`.
  public func stream(_ command: TartCommand, standardInput: Data? = nil) -> TartOperation {
    TartOperation(command: command, environment: environment, standardInput: standardInput)
  }

  /// Launches `tart run` detached from the app, appending its output to `logFile`.
  ///
  /// The VM keeps running if the app quits. Control it afterwards with `send(_:toVM:)` or
  /// `tart stop`, which work for any running VM no matter who started it.
  public func launch(_ options: RunOptions, logFile: URL) throws -> RunningVMProcess {
    let command = TartCommand.run(options)
    return try RunningVMProcess.spawn(
      executable: environment.executable,
      arguments: command.arguments,
      environment: ProcessEnvironment.merged(environment.variables(forRun: true), removing: ["CI"]),
      logFile: logFile,
      commandLine: command.commandLine,
      vmName: options.name
    )
  }

  /// Sends a control signal to the `tart run` process that holds the VM's lock.
  ///
  /// `.requestGuestShutdown` (SIGUSR2) asks the guest OS to shut down cleanly, which no `tart`
  /// subcommand offers; `.powerOff` is what `tart stop` does; `.suspend` needs `--suspendable`.
  public func send(_ signal: RunningVMSignal, toVM name: String) throws {
    guard let pid = VMLock.holderPID(vmNamed: name, paths: environment.paths) else {
      throw TartError(
        command: "kill -\(signal.signalNumber) (\(name))",
        exitCode: TartExitCode.vmStateError,
        message: "VM “\(name)” is not running."
      )
    }
    guard kill(pid, signal.signalNumber) == 0 else {
      throw TartError(
        command: "kill -\(signal.signalNumber) \(pid)",
        exitCode: TartExitCode.failure,
        message: "Couldn't signal VM “\(name)”: \(errnoDescription())"
      )
    }
  }

  /// The PID of the process currently holding the VM's lock (normally `tart run`).
  public func runningProcessIdentifier(ofVM name: String) -> Int32? {
    VMLock.holderPID(vmNamed: name, paths: environment.paths)
  }

  // MARK: - Introspection

  /// What the installed Tart supports, from `tart --experimental-dump-help` (cached once known).
  /// Returns `.unknown` (which permits everything) when the dump isn't available.
  public func capabilities() async -> TartCapabilities {
    if let cached = capabilityCache.current { return cached }
    let request = ProcessRequest(
      executable: environment.executable,
      arguments: ["--experimental-dump-help"],
      environment: environment.variables(forRun: false),
      timeout: .seconds(15)
    )
    guard
      let output = try? await runner.run(request), output.succeeded,
      let capabilities = try? TartCapabilities.parse(dumpHelp: output.stdout)
    else {
      return .unknown
    }
    capabilityCache.withLock { $0 = capabilities }
    return capabilities
  }
}
