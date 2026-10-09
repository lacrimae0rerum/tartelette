import Foundation

/// A child process whose stdout and stderr are delivered incrementally.
///
/// Completion fires exactly once, after the process has exited and both output streams reached
/// EOF (or a short grace period elapsed, in case a grandchild keeps a pipe open).
///
/// Per stream, data delivery and the close handler are serialized: a chunk whose delivery has
/// started always lands before the close handler, and output that arrives after a stream was
/// closed by the grace period is dropped.
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
    /// Set when a stream's EOF is claimed, before its close handler runs; the matching `…Open`
    /// flag is cleared only after the handler returns.
    var stdoutClosing = false
    var stderrClosing = false
    var exitStatus: Int32?
    var completion: (@Sendable (Int32) -> Void)?
    var launched = false
    var finished = false
  }

  /// How long to wait for EOF after the process exits before giving up on the streams.
  static let defaultStreamGracePeriod: TimeInterval = 2
  private let streamGracePeriod: TimeInterval

  private let process = Process()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let standardInput: Data?
  private let handlers: Handlers
  private let state = Locked(State())
  /// Serialize each stream's deliveries with its close (see the type's documentation).
  private let stdoutGate = NSLock()
  private let stderrGate = NSLock()

  init(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    standardInput: Data?,
    handlers: Handlers,
    streamGracePeriod: TimeInterval = ChildProcess.defaultStreamGracePeriod
  ) {
    self.streamGracePeriod = streamGracePeriod
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
        self.deliver(data, standardOutput: true)
      }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil
        self.closeStream(standardOutput: false)
      } else {
        self.deliver(data, standardOutput: false)
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

  /// Runs the stream's close handler once, then marks the stream closed.
  ///
  /// The stream only counts as closed after its handler returned: callers flush their final
  /// partial line there, and completion (which requires both streams closed) must never
  /// overtake that flush from the other stream's thread.
  private func closeStream(standardOutput: Bool) {
    let gate = standardOutput ? stdoutGate : stderrGate
    // Waits for an in-flight delivery of this stream to finish before closing it.
    gate.lock()
    let claimed = state.withLock { state -> Bool in
      if standardOutput {
        guard !state.stdoutClosing else { return false }
        state.stdoutClosing = true
      } else {
        guard !state.stderrClosing else { return false }
        state.stderrClosing = true
      }
      return true
    }
    if claimed {
      if standardOutput { handlers.standardOutputClosed() } else { handlers.standardErrorClosed() }
    }
    gate.unlock()
    guard claimed else { return }
    state.withLock { state in
      if standardOutput { state.stdoutOpen = false } else { state.stderrOpen = false }
    }
    finishIfComplete()
  }

  /// Hands a chunk to the stream's handler unless the stream was already closed.
  private func deliver(_ data: Data, standardOutput: Bool) {
    let gate = standardOutput ? stdoutGate : stderrGate
    gate.lock()
    defer { gate.unlock() }
    let closing = state.withLock { standardOutput ? $0.stdoutClosing : $0.stderrClosing }
    guard !closing else { return }
    if standardOutput { handlers.standardOutput(data) } else { handlers.standardError(data) }
  }

  private func markExited(_ status: Int32) {
    state.withLock { $0.exitStatus = status }
    finishIfComplete()
    DispatchQueue.global().asyncAfter(deadline: .now() + streamGracePeriod) { [self] in
      // A grandchild may hold the pipes open; stop waiting for EOF.
      if state.withLock({ !$0.stdoutClosing }) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        closeStream(standardOutput: true)
      }
      if state.withLock({ !$0.stderrClosing }) {
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
