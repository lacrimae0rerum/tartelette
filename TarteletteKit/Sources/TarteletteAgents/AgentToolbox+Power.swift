import Foundation
import TarteletteCLI
import TarteletteCore

/// What `start_vm` reports.
public struct AgentStartResult: Codable, Sendable, Equatable {
  public var name: String
  public var state: String
  /// The VM was already running, so nothing was launched.
  public var alreadyRunning: Bool
  /// Whether the guest agent answered; nil when the call didn't wait for it.
  public var guestAgentReady: Bool?

  public init(name: String, state: String, alreadyRunning: Bool, guestAgentReady: Bool?) {
    self.name = name
    self.state = state
    self.alreadyRunning = alreadyRunning
    self.guestAgentReady = guestAgentReady
  }
}

/// What `stop_vm` reports.
public struct AgentStopResult: Codable, Sendable, Equatable {
  public enum Method: String, Codable, Sendable {
    /// The VM wasn't running.
    case alreadyStopped
    /// The guest OS shut down when asked.
    case guestShutdown
    /// Tart powered the VM off.
    case powerOff
  }

  public var name: String
  public var state: String
  public var method: Method

  public init(name: String, state: String, method: Method) {
    self.name = name
    self.state = state
    self.method = method
  }
}

extension AgentToolbox {
  public static let defaultStartTimeoutSeconds = 180
  public static let maxStartTimeoutSeconds = 600
  public static let defaultStopTimeoutSeconds = 60
  public static let maxStopTimeoutSeconds = 600

  /// `start_vm` (start): launches the VM headless, detached, logging to `<logs>/<name>.log` like
  /// the app, so the app adopts it. A running VM is left as it is.
  ///
  /// - Parameters:
  ///   - wait: Wait until the guest agent answers, polling every two seconds.
  ///   - timeout: Seconds to wait (default 180, at most 600).
  public func startVM(name: String, wait: Bool = false, timeout: Int? = nil) async throws -> AgentStartResult {
    try await perform(.startVM, vm: name) { context in
      try authorize(.start, vm: name, in: context)
      let seconds = Self.seconds(timeout, default: Self.defaultStartTimeoutSeconds, maximum: Self.maxStartTimeoutSeconds)
      let result = try await start(name, wait: wait, timeoutSeconds: seconds)
      var detail = result.alreadyRunning ? "already running" : "started"
      switch result.guestAgentReady {
      case true?: detail += ", guest agent ready"
      case false?: detail += ", guest agent didn't answer within \(seconds) s"
      case nil: break
      }
      return (result, detail)
    }
  }

  /// `stop_vm` (stop): asks the guest OS to shut down and powers the VM off if it hasn't stopped
  /// after `timeout` seconds (default 60, at most 600). `force` powers it off at once.
  public func stopVM(name: String, force: Bool = false, timeout: Int? = nil) async throws -> AgentStopResult {
    try await perform(.stopVM, vm: name) { context in
      guard try authorize(.stop, vm: name, in: context) != nil else { throw AgentToolError.vmNotFound(name) }
      let seconds = Self.seconds(timeout, default: Self.defaultStopTimeoutSeconds, maximum: Self.maxStopTimeoutSeconds)
      let method = try await stop(name, force: force, timeout: .seconds(seconds))
      return (AgentStopResult(name: name, state: VMState.stopped.rawValue, method: method), method.rawValue)
    }
  }

  // MARK: - Shared with the sandbox tools

  /// Starts a VM the caller has authorized.
  func start(_ name: String, wait: Bool, timeoutSeconds: Int) async throws -> AgentStartResult {
    let vms = try await localVMs()
    guard let vm = vms.first(where: { $0.name == name }) else { throw AgentToolError.vmNotFound(name) }
    if vm.state.isRunning {
      let ready = wait ? try await waitForGuestAgent(name, launched: nil, timeout: .seconds(timeoutSeconds)) : nil
      return AgentStartResult(name: name, state: vm.state.rawValue, alreadyRunning: true, guestAgentReady: ready)
    }
    try checkMacOSGuestLimit(starting: name, among: vms)

    let logFile = agentPaths.logs.appendingPathComponent("\(name).log")
    // Measured before launching: `tart run` can fail and write its error before `launch` returns.
    let logOffset = Self.size(of: logFile)
    let launch = LaunchedVM(
      process: try client.launch(RunOptions(name: name, display: .headless), logFile: logFile),
      logOffset: logOffset)
    var ready: Bool?
    if wait {
      ready = try await waitForGuestAgent(name, launched: launch, timeout: .seconds(timeoutSeconds))
    } else {
      try launch.checkStillRunning()
    }
    return AgentStartResult(name: name, state: VMState.running.rawValue, alreadyRunning: false, guestAgentReady: ready)
  }

  /// Stops a VM the caller has authorized: guest shutdown, then power off; `force` skips the former.
  func stop(_ name: String, force: Bool, timeout: Duration) async throws -> AgentStopResult.Method {
    guard isRunning(name) else { return .alreadyStopped }
    if !force {
      do {
        try client.send(.requestGuestShutdown, toVM: name)
      } catch let error as TartError where error.isVMStateError {
        return .alreadyStopped  // It stopped in the meantime.
      }
      if try await waitUntilStopped(name, timeout: timeout) { return .guestShutdown }
    }
    try await powerOff(name)
    return .powerOff
  }

  /// `tart stop`, which powers the VM off. A VM that stopped on its own is what was asked for.
  func powerOff(_ name: String) async throws {
    do {
      try await client.execute(.stop(name: name), timeout: .seconds(TartCommand.defaultStopTimeoutSeconds + 30))
    } catch let error as TartError where error.isVMStateError {
      return
    }
  }

  /// Whether a process (normally `tart run`) holds the VM's lock.
  func isRunning(_ name: String) -> Bool {
    client.runningProcessIdentifier(ofVM: name) != nil
  }

  /// Polls the VM's lock every second; returns whether the VM stopped within `timeout`.
  func waitUntilStopped(_ name: String, timeout: Duration) async throws -> Bool {
    let deadline = clock.now() + timeout
    while isRunning(name) {
      guard clock.now() < deadline else { return false }
      try await clock.sleep(.seconds(1))
    }
    return true
  }

  // MARK: - Helpers

  /// A `tart run` just launched, and where its output starts in the log.
  private struct LaunchedVM {
    let process: RunningVMProcess
    let logOffset: UInt64

    /// Throws `startFailed`, with the end of this launch's log, once `tart run` has exited.
    func checkStillRunning() throws {
      guard process.exitCode != nil else { return }
      throw AgentToolError.startFailed(
        vm: process.vmName, logTail: AgentToolbox.logTail(process.logFile, from: logOffset, lines: 10))
    }
  }

  /// Polls the guest agent every two seconds until it answers (true) or `timeout` passes (false).
  private func waitForGuestAgent(_ name: String, launched: LaunchedVM?, timeout: Duration) async throws -> Bool {
    let deadline = clock.now() + timeout
    while true {
      try launched?.checkStillRunning()
      if await guestReadiness(name) { return true }
      try launched?.checkStillRunning()
      guard clock.now() < deadline else { return false }
      try await clock.sleep(.seconds(2))
    }
  }

  /// Refuses to start a macOS VM while the host already runs as many macOS guests as
  /// Virtualization.framework allows, counting them as the app does.
  private func checkMacOSGuestLimit(starting name: String, among vms: [VMListing]) throws {
    guard operatingSystem(of: name) == .macOS else { return }
    let runningMacs = vms.filter { $0.name != name && $0.state.isRunning && operatingSystem(of: $0.name) == .macOS }
    if runningMacs.count >= VirtualizationLimits.maximumConcurrentMacOSGuests {
      throw AgentToolError.macOSGuestLimitReached(vm: name)
    }
  }

  private func operatingSystem(of name: String) -> VMOperatingSystem {
    (try? client.configuration(of: name))?.operatingSystem ?? .unknown
  }

  /// `requested` when positive, capped at `maximum`; otherwise `fallback`.
  static func seconds(_ requested: Int?, default fallback: Int, maximum: Int) -> Int {
    guard let requested, requested > 0 else { return fallback }
    return min(requested, maximum)
  }

  private static func size(of file: URL) -> UInt64 {
    (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
  }

  /// The last `lines` non-empty lines written to `file` after `offset`, reading at most 16 KB.
  static func logTail(_ file: URL, from offset: UInt64, lines: Int) -> String {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: max(offset, size > 16_384 ? size - 16_384 : 0))
    let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
  }
}
