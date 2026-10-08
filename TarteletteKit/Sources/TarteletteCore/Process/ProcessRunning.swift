import Foundation

/// Captured result of a finished child process.
public struct CommandOutput: Sendable, Equatable {
  public var status: Int32
  public var stdout: Data
  public var stderr: Data

  public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public var succeeded: Bool { status == 0 }
  public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
  public var stderrString: String { String(decoding: stderr, as: UTF8.self) }

  /// The most useful human-readable diagnostic: stderr when present, otherwise stdout.
  public var diagnostic: String {
    let err = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
    if !err.isEmpty { return err }
    return stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A request to spawn a process.
public struct ProcessRequest: Sendable, Equatable {
  public var executable: URL
  public var arguments: [String]
  /// Extra variables merged over the inherited environment.
  public var environment: [String: String]
  public var standardInput: Data?
  public var timeout: Duration?

  public init(
    executable: URL,
    arguments: [String],
    environment: [String: String] = [:],
    standardInput: Data? = nil,
    timeout: Duration? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.standardInput = standardInput
    self.timeout = timeout
  }
}

public enum ProcessRunError: Error, Sendable, Equatable, LocalizedError {
  case launchFailed(String)
  case timedOut(after: Duration)
  case cancelled
  case failed(status: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case .launchFailed(let reason): "Could not launch process: \(reason)"
    case .timedOut(let after): "The operation timed out after \(after.formatted(.units(allowed: [.seconds], width: .wide)))."
    case .cancelled: "The operation was cancelled."
    case .failed(let status, let message):
      message.isEmpty ? "The command failed with exit code \(status)." : message
    }
  }
}

/// Port: runs a process to completion and captures its output.
///
/// Implementations must honour `timeout` and task cancellation by terminating the child.
public protocol ProcessRunning: Sendable {
  func run(_ request: ProcessRequest) async throws -> CommandOutput
}
