import Foundation
import TarteletteCore

/// Whether guest commands (and therefore the clipboard bridge and guest metrics) work for a VM.
public enum GuestAgentStatus: Sendable, Equatable {
  case unknown
  case checking
  case available(user: String, isRoot: Bool)
  case unavailable(reason: String)

  public var isAvailable: Bool {
    if case .available = self { true } else { false }
  }
}

/// Checks that a transport reaches a usable guest session.
public struct GuestProbe: Sendable {
  /// The probe prints user name, uid, kernel name and (on macOS) the console owner.
  public static let command = [
    "/usr/bin/env", "LANG=en_US.UTF-8", "/bin/sh", "-c",
    "id -un; id -u; uname -s; if [ \"$(uname -s)\" = Darwin ]; then /usr/bin/stat -f %Su /dev/console 2>/dev/null; fi",
  ]

  public static func probe(_ transport: any GuestTransport, timeout: Duration = .seconds(8)) async -> GuestAgentStatus {
    do {
      let output = try await transport.run(command, standardInput: nil, timeout: timeout)
      return interpret(output)
    } catch ProcessRunError.timedOut {
      return .unavailable(reason: Reason.timedOut)
    } catch ProcessRunError.cancelled {
      return .unknown
    } catch {
      return .unavailable(reason: friendlyReason(for: error.localizedDescription, status: nil))
    }
  }

  /// Maps probe output to a status. Exposed for tests.
  public static func interpret(_ output: CommandOutput) -> GuestAgentStatus {
    guard output.succeeded else {
      return .unavailable(reason: friendlyReason(for: output.diagnostic, status: output.status))
    }
    let lines = output.stdoutString
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count >= 3 else {
      return .unavailable(reason: "The guest answered, but not as expected: \(output.stdoutString.prefix(120))")
    }
    let user = lines[0]
    let isRoot = lines[1] == "0"
    if lines[2] == "Darwin", lines.count >= 4, lines[3] == "root" {
      return .unavailable(reason: Reason.loginWindow)
    }
    return .available(user: user, isRoot: isRoot)
  }

  enum Reason {
    static let agentMissing =
      "The Tart Guest Agent isn't reachable in this VM. Use a Cirrus Labs base or Xcode image, or install "
      + "tart-guest-agent in the guest."
    static let notRunning = "The VM isn't running."
    static let timedOut =
      "The guest didn't respond in time. It may still be booting, or the Tart Guest Agent may be missing."
    static let loginWindow =
      "Nobody is logged in to the guest's desktop yet. Log in (or enable automatic login) to use the clipboard."
    static let hostTooOld = "Guest commands need macOS 14 Sonoma or newer on this Mac."
    static let sshAuth = "SSH authentication failed. Check the user name and password."
    static let sshUnreachable = "SSH isn't reachable. Enable Remote Login in the guest and check its IP address."
  }

  static func friendlyReason(for message: String, status: Int32?) -> String {
    let lowered = message.lowercased()
    if lowered.contains("guest agent") || lowered.contains("control socket") { return Reason.agentMissing }
    if lowered.contains("is not running") { return Reason.notRunning }
    if lowered.contains("only available on macos 14") { return Reason.hostTooOld }
    if lowered.contains("permission denied") { return Reason.sshAuth }
    if lowered.contains("connection refused") || lowered.contains("timed out") || lowered.contains("no route to host")
      || lowered.contains("could not resolve")
    {
      return Reason.sshUnreachable
    }
    if status == 125 { return "The guest could not start the probe command." }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty, let status { return "The guest command failed with exit code \(status)." }
    return trimmed
  }
}
