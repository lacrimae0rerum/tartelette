import Foundation
import TarteletteCore

/// A long-running `tart` command (pull, push, clone, create, import, export, exec…) whose output
/// is delivered as it happens.
///
/// The command starts as soon as the operation is created. `events` is a single-consumer stream:
/// iterate it from one task. It always ends with exactly one `.finished` event.
public final class TartOperation: Sendable {
  public enum Event: Sendable, Equatable {
    /// The process launched.
    case started(pid: Int32)
    /// One line of output, ANSI-stripped. Progress lines (`N%`) are reported as `.progress` instead.
    case line(String, isError: Bool)
    /// The latest phase line on stdout, e.g. `pulling disk (12.3 GB compressed)...`.
    case status(String)
    /// Progress of the current phase in 0...1.
    case progress(Double)
    /// The process exited. `message` holds Tart's cleaned diagnostic when `exitCode != 0`.
    case finished(exitCode: Int32, message: String?)
  }

  private struct State {
    var started = false
    var pending: [Event] = []
    var stdoutLines = LineSplitter()
    var stderrLines = LineSplitter()
    var parser = TartProgressParser()
    var stderrText = ""
    var lastStatus: String?
    var cancelled = false
  }

  /// Keep at most this much stderr for the final diagnostic.
  private static let stderrLimit = 64 * 1024

  public let command: TartCommand
  public let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let state = Locked(State())
  private let child: ChildProcess

  init(command: TartCommand, environment: TartEnvironment, standardInput: Data?) {
    self.command = command
    (events, continuation) = AsyncStream<Event>.makeStream()

    let isRun = if case .run = command { true } else { false }
    let state = self.state
    let continuation = self.continuation

    @Sendable func emit(_ event: Event) {
      state.withLock { state in
        guard state.started else {
          state.pending.append(event)
          return
        }
        continuation.yield(event)
        if case .finished = event { continuation.finish() }
      }
    }

    @Sendable func handleStandardOutput(_ lines: [String]) {
      for line in lines where !line.isEmpty {
        let event = state.withLock { state -> TartProgressParser.Event? in
          let event = state.parser.consume(line: line)
          if case .status(let status) = event { state.lastStatus = status }
          return event
        }
        switch event {
        case .progress(let fraction): emit(.progress(fraction))
        case .status(let status):
          emit(.line(status, isError: false))
          emit(.status(status))
        case nil: break
        }
      }
    }

    @Sendable func handleStandardError(_ lines: [String]) {
      for line in lines where !line.isEmpty {
        state.withLock { state in
          if state.stderrText.utf8.count < Self.stderrLimit { state.stderrText += line + "\n" }
        }
        emit(.line(line, isError: true))
      }
    }

    child = ChildProcess(
      executable: environment.executable,
      arguments: command.arguments,
      environment: ProcessEnvironment.merged(
        environment.variables(forRun: isRun), removing: isRun ? ["CI"] : []),
      standardInput: standardInput,
      handlers: .init(
        standardOutput: { data in handleStandardOutput(state.withLock { $0.stdoutLines.append(data) }) },
        standardError: { data in handleStandardError(state.withLock { $0.stderrLines.append(data) }) },
        standardOutputClosed: { handleStandardOutput(state.withLock { $0.stdoutLines.flush() }) },
        standardErrorClosed: { handleStandardError(state.withLock { $0.stderrLines.flush() }) }
      )
    )

    do {
      try child.start { status in
        let message: String? = state.withLock { state in
          guard status != 0 else { return nil }
          let cleaned = TartError.cleanMessage(state.stderrText)
          if !cleaned.isEmpty { return cleaned }
          if state.cancelled { return "Cancelled." }
          return state.lastStatus ?? "tart exited with code \(status)."
        }
        emit(.finished(exitCode: status, message: message))
      }
      markStarted(with: .started(pid: child.processIdentifier))
    } catch {
      let message = "Could not launch \(environment.executable.path): \(error.localizedDescription)"
      emit(.line(message, isError: true))
      emit(.finished(exitCode: -1, message: message))
      markStarted(with: nil)
    }
  }

  /// The PID of the `tart` process, or nil if it failed to launch.
  public var processIdentifier: Int32? {
    let pid = child.processIdentifier
    return pid > 0 ? pid : nil
  }

  /// Whether the process is still running.
  public var isRunning: Bool { child.isRunning }

  /// Asks Tart to stop by sending SIGINT; Tart cancels the work and cleans up temporary files.
  public func cancel() {
    state.withLock { $0.cancelled = true }
    child.send(SIGINT)
  }

  /// Forcefully terminates the process (SIGTERM). Prefer `cancel()`, which lets Tart clean up.
  public func terminate() {
    state.withLock { $0.cancelled = true }
    child.send(SIGTERM)
  }

  /// Waits for the operation to finish and returns its exit code and diagnostic.
  ///
  /// This consumes `events`; don't call it if you also iterate the stream yourself.
  public func result() async -> (exitCode: Int32, message: String?) {
    for await event in events {
      if case .finished(let exitCode, let message) = event { return (exitCode, message) }
    }
    return (-1, "The operation ended unexpectedly.")
  }

  private func markStarted(with first: Event?) {
    state.withLock { state in
      if let first { continuation.yield(first) }
      for event in state.pending {
        continuation.yield(event)
        if case .finished = event { continuation.finish() }
      }
      state.pending.removeAll()
      state.started = true
    }
  }
}
