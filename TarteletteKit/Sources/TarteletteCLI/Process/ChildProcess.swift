import Foundation

/// A child process whose stdout and stderr are delivered incrementally.
///
/// Completion fires exactly once, after the process has exited and both output streams reached
/// EOF (or a short grace period elapsed, in case a grandchild keeps a pipe open).
final class ChildProcess: @unchecked Sendable {
  struct Handlers: Sendable {
    var standardOutput: @Sendable (Data) -> Void
    var standardError: @Sendable (Data) -> Void
    /// Called once when stdout reaches EOF, before completion.
    var standardOutputClosed: @Sendable () -> Void = {}
    /// Called once when stderr reaches EOF, before completion.
    var standardErrorClosed: @Sendable () -> Void = {}
  }

  private struct State {
    var stdoutOpen = true
    var stderrOpen = true
    var exitStatus: Int32?
    var completion: (@Sendable (Int32) -> Void)?
    var launched = false
    var finished = false
  }

  /// How long to wait for EOF after the process exits before giving up on the streams.
  private static let streamGracePeriod: TimeInterval = 2

  private let process = Process()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let standardInput: Data?
  private let handlers: Handlers
  private let state = Locked(State())

  init(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    standardInput: Data?,
    handlers: Handlers
  ) {
    self.standardInput = standardInput
    self.handlers = handlers
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
  }

  /// The child's PID, or 0 before launch.
  var processIdentifier: Int32 { process.processIdentifier }

  /// Whether the process has been launched and has not exited yet.
  var isRunning: Bool {
    state.withLock { $0.launched && $0.exitStatus == nil }
  }

  /// Launches the process. `completion` receives the exit status (128 + signal when killed).
  func start(completion: @escaping @Sendable (Int32) -> Void) throws {
    state.withLock { $0.completion = completion }

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil
        self.closeStream(standardOutput: true)
      } else {
        self.handlers.standardOutput(data)
      }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil
        self.closeStream(standardOutput: false)
      } else {
        self.handlers.standardError(data)
      }
    }
    process.terminationHandler = { [weak self] process in
      let status =
        process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
      self?.markExited(status)
    }

    let inputPipe: Pipe?
    if standardInput != nil {
      let pipe = Pipe()
      process.standardInput = pipe
      inputPipe = pipe
    } else {
      process.standardInput = FileHandle.nullDevice
      inputPipe = nil
    }

    do {
      try process.run()
    } catch {
      stdoutPipe.fileHandleForReading.readabilityHandler = nil
      stderrPipe.fileHandleForReading.readabilityHandler = nil
      state.withLock { $0.completion = nil }
      throw error
    }
    state.withLock { $0.launched = true }

    if let inputPipe, let standardInput {
      let writer = inputPipe.fileHandleForWriting
      // A child that exits without reading must not kill the app with SIGPIPE.
      _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
      DispatchQueue.global(qos: .userInitiated).async {
        try? writer.write(contentsOf: standardInput)
        try? writer.close()
      }
    }
  }

  /// Sends `signal` to the child if it is still running.
  func send(_ signal: Int32) {
    let pid = state.withLock { $0.launched && $0.exitStatus == nil ? process.processIdentifier : 0 }
    if pid > 0 { kill(pid, signal) }
  }

  /// SIGINT, then SIGTERM and finally SIGKILL while the child keeps running.
  func terminateEscalating(after grace: TimeInterval = 3) {
    send(SIGINT)
    DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
      guard let self, self.isRunning else { return }
      self.send(SIGTERM)
      DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
        guard let self, self.isRunning else { return }
        self.send(SIGKILL)
      }
    }
  }

  private func closeStream(standardOutput: Bool) {
    let shouldNotify = state.withLock { state -> Bool in
      if standardOutput {
        defer { state.stdoutOpen = false }
        return state.stdoutOpen
      } else {
        defer { state.stderrOpen = false }
        return state.stderrOpen
      }
    }
    if shouldNotify {
      if standardOutput { handlers.standardOutputClosed() } else { handlers.standardErrorClosed() }
    }
    finishIfComplete()
  }

  private func markExited(_ status: Int32) {
    state.withLock { $0.exitStatus = status }
    finishIfComplete()
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.streamGracePeriod) { [self] in
      // A grandchild may hold the pipes open; stop waiting for EOF.
      if state.withLock({ $0.stdoutOpen }) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        closeStream(standardOutput: true)
      }
      if state.withLock({ $0.stderrOpen }) {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        closeStream(standardOutput: false)
      }
    }
  }

  private func finishIfComplete() {
    let ready: ((@Sendable (Int32) -> Void), Int32)? = state.withLock { state in
      guard !state.finished, !state.stdoutOpen, !state.stderrOpen, let status = state.exitStatus,
        let completion = state.completion
      else { return nil }
      state.finished = true
      state.completion = nil
      return (completion, status)
    }
    if let (completion, status) = ready { completion(status) }
  }
}
