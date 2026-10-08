import Foundation
import TarteletteCore

/// A `tart` invocation that exited unsuccessfully (or could not be performed).
public struct TartError: LocalizedError, Sendable, Equatable {
  /// The command line that failed, with secrets masked.
  public var command: String
  public var exitCode: Int32
  /// Tart's diagnostic, cleaned of `Error:` prefixes and usage boilerplate.
  public var message: String

  public init(command: String, exitCode: Int32, message: String) {
    self.command = command
    self.exitCode = exitCode
    self.message = message
  }

  /// The VM does not exist, is not running, or is already running (exit code 2).
  public var isVMStateError: Bool { exitCode == TartExitCode.vmStateError }

  /// Invalid arguments or failed validation (exit code 64).
  public var isUsageError: Bool { exitCode == TartExitCode.usageError }

  public var errorDescription: String? {
    message.isEmpty ? "“\(command)” failed with exit code \(exitCode)." : message
  }

  public var failureReason: String? {
    "\(command) exited with code \(exitCode)."
  }

  /// Removes `Error: ` prefixes, usage hints and auxiliary noise from Tart's stderr.
  public static func cleanMessage(_ raw: String) -> String {
    let lines = TartProgressParser.stripANSI(raw)
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in
        !line.isEmpty && !line.hasPrefix("Usage:") && !line.hasPrefix("See 'tart")
          && !line.hasPrefix("See 'tart help")
      }
      .map { line in line.hasPrefix("Error: ") ? String(line.dropFirst("Error: ".count)) : line }

    // Garbage-collection warnings precede the real error; keep them only if nothing else is left.
    let substantive = lines.filter { !$0.hasPrefix("Failed to perform garbage collection") }
    return (substantive.isEmpty ? lines : substantive).joined(separator: "\n")
  }
}
