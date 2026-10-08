import Foundation
import TarteletteCore

/// Runs a process to completion and captures its output (adapter for the Core `ProcessRunning` port).
///
/// stdout and stderr are drained concurrently, so arbitrarily large output never deadlocks.
/// On timeout or task cancellation the child receives SIGINT, then SIGTERM and SIGKILL
/// three seconds apart while it keeps running. A non-zero exit status is returned, not thrown.
public struct ProcessRunner: ProcessRunning {
  public init() {}

  public func run(_ request: ProcessRequest) async throws -> CommandOutput {
    enum Outcome { case pending, timedOut, cancelled }

    let stdout = Locked(Data())
    let stderr = Locked(Data())
    let outcome = Locked(Outcome.pending)
    let child = ChildProcess(
      executable: request.executable,
      arguments: request.arguments,
      environment: ProcessEnvironment.merged(request.environment),
      standardInput: request.standardInput,
      handlers: .init(
        standardOutput: { data in stdout.withLock { $0.append(data) } },
        standardError: { data in stderr.withLock { $0.append(data) } }
      )
    )

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandOutput, any Error>) in
        do {
          try child.start { status in
            switch outcome.current {
            case .timedOut:
              continuation.resume(throwing: ProcessRunError.timedOut(after: request.timeout ?? .zero))
            case .cancelled:
              continuation.resume(throwing: ProcessRunError.cancelled)
            case .pending:
              continuation.resume(
                returning: CommandOutput(status: status, stdout: stdout.current, stderr: stderr.current))
            }
          }
        } catch {
          continuation.resume(throwing: ProcessRunError.launchFailed(Self.describeLaunchFailure(error, request)))
          return
        }

        if let timeout = request.timeout {
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
            guard child.isRunning else { return }
            let shouldStop = outcome.withLock { state -> Bool in
              guard case .pending = state else { return false }
              state = .timedOut
              return true
            }
            if shouldStop { child.terminateEscalating() }
          }
        }
        // Cancellation may have arrived before the child existed.
        if case .cancelled = outcome.current { child.terminateEscalating() }
      }
    } onCancel: {
      let shouldStop = outcome.withLock { state -> Bool in
        guard case .pending = state else { return false }
        state = .cancelled
        return true
      }
      if shouldStop { child.terminateEscalating() }
    }
  }

  private static func describeLaunchFailure(_ error: any Error, _ request: ProcessRequest) -> String {
    let path = request.executable.path
    if !FileManager.default.fileExists(atPath: path) { return "\(path) does not exist." }
    if !FileManager.default.isExecutableFile(atPath: path) { return "\(path) is not executable." }
    return "\(path): \(error.localizedDescription)"
  }
}
