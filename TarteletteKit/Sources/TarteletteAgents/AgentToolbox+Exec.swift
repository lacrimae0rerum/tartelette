import Foundation
import TarteletteCLI
import TarteletteCore
import TarteletteGuest

/// What `exec` reports.
public struct AgentExecResult: Codable, Sendable, Equatable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String
  public var stdoutTruncated: Bool
  public var stderrTruncated: Bool
  /// Bytes the command wrote to stdout, including any cut off.
  public var stdoutBytes: Int
  /// Bytes the command wrote to stderr, including any cut off.
  public var stderrBytes: Int

  public init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    stdoutTruncated: Bool,
    stderrTruncated: Bool,
    stdoutBytes: Int,
    stderrBytes: Int
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
    self.stdoutBytes = stdoutBytes
    self.stderrBytes = stderrBytes
  }
}

extension AgentToolbox {
  /// `exec` (exec): runs a shell command in a running VM through the Tart Guest Agent.
  ///
  /// The command runs in a login shell (`/bin/sh -lc`) with a UTF-8 locale, like the app's console,
  /// so it sees the guest user's PATH.
  ///
  /// - Parameters:
  ///   - command: A shell command line.
  ///   - standardInput: Text passed to the command's stdin; never recorded in the audit log.
  ///   - timeout: Seconds (default and maximum from the user's agent limits).
  public func exec(
    name: String,
    command: String,
    standardInput: String? = nil,
    timeout: Int? = nil
  ) async throws -> AgentExecResult {
    try await perform(.exec, vm: name) { context in
      try authorize(.exec, vm: name, in: context)
      guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.contains("\u{0}") else {
        throw AgentToolError.invalidCommand
      }
      let limits = context.policy.limits
      let seconds = Self.seconds(timeout, default: limits.execTimeoutDefaultSeconds, maximum: limits.execTimeoutMaxSeconds)
      let guest = try await runningGuest(name)
      let locale = guest.os == .linux ? "LANG=C.UTF-8" : "LANG=en_US.UTF-8"
      let output: CommandOutput
      do {
        output = try await guest.transport.run(
          ["/usr/bin/env", locale, "/bin/sh", "-lc", command], standardInput: standardInput.map { Data($0.utf8) },
          timeout: .seconds(seconds))
      } catch ProcessRunError.timedOut {
        throw AgentToolError.commandTimedOut(vm: name, seconds: seconds)
      }
      if let failure = Self.tartExecFailure(output, vm: name) { throw failure }
      let stdout = Self.text(output.stdout, limit: limits.maxOutputBytes)
      let stderr = Self.text(output.stderr, limit: limits.maxOutputBytes)
      let result = AgentExecResult(
        exitCode: output.status, stdout: stdout.text, stderr: stderr.text, stdoutTruncated: stdout.truncated,
        stderrTruncated: stderr.truncated, stdoutBytes: output.stdout.count, stderrBytes: output.stderr.count)
      return (result, "exit \(output.status): \(command)")
    }
  }

  /// `tart exec`'s own failure, as opposed to the command's: it couldn't reach the guest agent, or
  /// the VM stopped meanwhile. Matched narrowly (tart's exit status, nothing on stdout, tart's
  /// "Error:" message) because the command itself may fail with similar words.
  static func tartExecFailure(_ output: CommandOutput, vm name: String) -> AgentToolError? {
    let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard output.stdout.isEmpty, message.hasPrefix("error:") else { return nil }
    if output.status == 1, message.contains("control socket") || message.contains("guest agent") {
      return .guestAgentUnreachable(name)
    }
    if output.status == 2, message.contains("vm \"\(name.lowercased())\" is not running") {
      return .vmNotRunning(name)
    }
    return nil
  }

  /// `data` decoded as UTF-8 (invalid bytes become U+FFFD), cut to at most `limit` bytes without
  /// splitting a character; `truncated` tells whether anything was cut.
  static func text(_ data: Data, limit: Int) -> (text: String, truncated: Bool) {
    guard data.count > limit else { return (String(decoding: data, as: UTF8.self), false) }
    var end = data.startIndex + limit
    // Step back over continuation bytes (10xxxxxx) to the start of the character being cut.
    for _ in 0..<3 where end > data.startIndex && data[end] & 0xC0 == 0x80 {
      end -= 1
    }
    return (String(decoding: data[data.startIndex..<end], as: UTF8.self), true)
  }

  // MARK: - Shared with the file tools

  /// The guest of a VM the caller has authorized, which must be running.
  func runningGuest(_ name: String) async throws -> GuestEndpoint {
    guard try await localVM(named: name).state.isRunning else { throw AgentToolError.vmNotRunning(name) }
    return GuestEndpoint(vmName: name, os: operatingSystem(of: name), transport: guestTransport(name))
  }
}
