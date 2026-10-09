import Foundation
import TarteletteCore

/// Runs commands inside a guest VM.
///
/// Transports return the guest command's output even when it exits non-zero; they only throw when
/// the command could not be delivered at all (launch failure, timeout, cancellation).
public protocol GuestTransport: Sendable {
  /// Short human-readable description, e.g. `tart exec dev` or `ssh admin@192.168.64.3`.
  var label: String { get }

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput
}

extension GuestTransport {
  public func run(_ command: [String], timeout: Duration? = nil) async throws -> CommandOutput {
    try await run(command, standardInput: nil, timeout: timeout)
  }
}

public enum GuestTransportError: Error, Sendable, Equatable, LocalizedError {
  /// The guest command ran but failed.
  case commandFailed(status: Int32, message: String)
  /// The guest replied with output the bridge could not understand.
  case unexpectedOutput(String)
  /// The guest lacks a capability (clipboard tool, desktop session, …).
  case unsupported(String)
  /// Data arrived corrupted even after retries.
  case integrityCheckFailed(String)
  /// A payload exceeded the configured limit.
  case tooLarge(bytes: Int, limit: Int)
  /// The command never reached the guest (agent missing, VM stopped, SSH unreachable). Transient:
  /// retrying later can succeed.
  case unreachable(String)

  public var errorDescription: String? {
    switch self {
    case .unreachable(let reason): reason
    case .commandFailed(let status, let message):
      message.isEmpty ? "The guest command failed with exit code \(status)." : message
    case .unexpectedOutput(let detail): "The guest returned unexpected output: \(detail)"
    case .unsupported(let reason): reason
    case .integrityCheckFailed(let detail): "The transfer could not be verified: \(detail)"
    case .tooLarge(let bytes, let limit):
      "The clipboard holds \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
        + "more than the automatic limit of \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
    }
  }
}

/// File transfers the bridge refuses before moving anything.
public enum GuestTransferError: Error, Sendable, Equatable, LocalizedError {
  /// Several selected items share a name; copying them into one folder would overwrite some.
  case duplicateNames([String])
  /// The clipboard is still being handed over by its writer (some item didn't resolve yet).
  case incomplete

  public var errorDescription: String? {
    switch self {
    case .duplicateNames(let names):
      "Several items are named \(names.map { "“\($0)”" }.joined(separator: ", ")). Copy them separately or rename them first."
    case .incomplete:
      "The clipboard is still being written. Try again in a moment."
    }
  }

  /// Throws `duplicateNames` when two items would land on the same name.
  static func checkUniqueNames(_ names: [String]) throws {
    var seen: Set<String> = []
    var duplicates: [String] = []
    for name in names where !seen.insert(name).inserted && !duplicates.contains(name) {
      duplicates.append(name)
    }
    if !duplicates.isEmpty { throw GuestTransferError.duplicateNames(duplicates) }
  }
}

/// Delivers guest commands through `tart exec`, i.e. the Tart Guest Agent's gRPC channel.
///
/// The agent runs as the logged-in GUI user on Cirrus Labs images, so pasteboard tools work.
public struct TartExecTransport: GuestTransport {
  public let vmName: String
  public let tartExecutable: URL
  public let environment: [String: String]
  private let runner: any ProcessRunning

  public init(vmName: String, tartExecutable: URL, environment: [String: String], runner: any ProcessRunning) {
    self.vmName = vmName
    self.tartExecutable = tartExecutable
    self.environment = environment
    self.runner = runner
  }

  public var label: String { "tart exec \(vmName)" }

  /// The argv passed to `tart` for a guest command; `-i` is added only when stdin is supplied.
  public func arguments(for command: [String], hasStandardInput: Bool) -> [String] {
    ExecOptions(name: vmName, command: command, interactive: hasStandardInput).arguments
  }

  public func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    let request = ProcessRequest(
      executable: tartExecutable,
      arguments: arguments(for: command, hasStandardInput: standardInput != nil),
      environment: environment,
      standardInput: standardInput,
      timeout: timeout
    )
    return try await runner.runCapturingFailures(request)
  }
}

extension ProcessRunning {
  /// Runs a request and folds `ProcessRunError.failed` into a `CommandOutput`, so callers can treat
  /// runners that throw on non-zero exit and runners that don't the same way.
  func runCapturingFailures(_ request: ProcessRequest) async throws -> CommandOutput {
    do {
      return try await run(request)
    } catch ProcessRunError.failed(let status, let message) {
      return CommandOutput(status: status, stdout: Data(), stderr: Data(message.utf8))
    }
  }
}
