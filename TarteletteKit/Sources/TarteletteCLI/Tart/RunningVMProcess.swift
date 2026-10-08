import Foundation
import TarteletteCore

/// A `tart run` process launched by the app.
///
/// The process runs in its own session with stdout and stderr appended to a log file, so the VM
/// keeps running after the app quits. The app reaps it when it exits, so no zombie is left behind.
public final class RunningVMProcess: Sendable {
  private struct State {
    var exitCode: Int32?
    var waiters: [CheckedContinuation<Int32, Never>] = []
    var source: (any DispatchSourceProcess)?
  }

  /// Keeps launched processes (and their exit sources) alive until they have been reaped.
  private static let live = Locked([Int32: RunningVMProcess]())

  public let pid: Int32
  public let vmName: String
  public let logFile: URL
  /// The rendered command line (secrets masked).
  public let commandLine: String
  public let launchedAt: Date
  private let state = Locked(State())

  private init(pid: Int32, vmName: String, logFile: URL, commandLine: String, launchedAt: Date) {
    self.pid = pid
    self.vmName = vmName
    self.logFile = logFile
    self.commandLine = commandLine
    self.launchedAt = launchedAt
  }

  /// The exit code once the process has exited (128 + signal when it was killed).
  public var exitCode: Int32? { state.withLock { $0.exitCode } }

  public var isRunning: Bool { exitCode == nil }

  /// Suspends until the process exits and returns its exit code.
  public func waitForExit() async -> Int32 {
    await withCheckedContinuation { continuation in
      let finished = state.withLock { state -> Int32? in
        if let code = state.exitCode { return code }
        state.waiters.append(continuation)
        return nil
      }
      if let finished { continuation.resume(returning: finished) }
    }
  }

  // MARK: - Spawning

  static func spawn(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    logFile: URL,
    commandLine: String,
    vmName: String
  ) throws -> RunningVMProcess {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

    let logDescriptor = open(logFile.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard logDescriptor >= 0 else {
      throw TartError(command: commandLine, exitCode: -1, message: "Can't open log file \(logFile.path): \(errnoDescription())")
    }
    defer { close(logDescriptor) }

    let launchedAt = Date()
    let header = "\n=== \(ISO8601DateFormatter().string(from: launchedAt)) — \(commandLine) ===\n"
    _ = header.withCString { write(logDescriptor, $0, strlen($0)) }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fileActions, logDescriptor, 1)
    posix_spawn_file_actions_adddup2(&fileActions, logDescriptor, 2)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // New session (detached from the app), no inherited descriptors, default signal handling.
    let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))
    var defaultSignals = signalSet([SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGCHLD, SIGUSR1, SIGUSR2])
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    var emptyMask = sigset_t(0)
    posix_spawnattr_setsigmask(&attributes, &emptyMask)

    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable.path, &fileActions, &attributes, argv, envp)
    guard status == 0 else {
      throw TartError(
        command: commandLine, exitCode: -1,
        message: "Could not launch \(executable.path): \(String(cString: strerror(status)))")
    }

    let process = RunningVMProcess(
      pid: pid, vmName: vmName, logFile: logFile, commandLine: commandLine, launchedAt: launchedAt)
    process.monitorExit()
    return process
  }

  private func monitorExit() {
    Self.live.withLock { $0[pid] = self }
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
    source.setEventHandler { [self] in reap() }
    state.withLock { $0.source = source }
    source.activate()
    // The child may have exited before the source was registered.
    reap()
  }

  private func reap() {
    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, WNOHANG)
    } while result == -1 && errno == EINTR

    let code: Int32
    if result == pid {
      code = Self.decodeWaitStatus(status)
    } else if result == -1 {
      code = -1  // Already reaped elsewhere; the exit code is unknown.
    } else {
      return  // Still running.
    }

    let (waiters, source) = state.withLock { state -> ([CheckedContinuation<Int32, Never>], (any DispatchSourceProcess)?) in
      guard state.exitCode == nil else { return ([], nil) }
      state.exitCode = code
      defer {
        state.waiters.removeAll()
        state.source = nil
      }
      return (state.waiters, state.source)
    }
    source?.cancel()
    waiters.forEach { $0.resume(returning: code) }
    Self.live.withLock { $0[pid] = nil }
  }

  static func decodeWaitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    return 128 + signal
  }

  private static func signalSet(_ signals: [Int32]) -> sigset_t {
    signals.reduce(sigset_t(0)) { set, signal in set | sigset_t(1) << sigset_t(signal - 1) }
  }
}

func errnoDescription() -> String {
  String(cString: strerror(errno))
}
