import Foundation
import TarteletteCore
import TarteletteGuest
import os

/// Runs "guest" commands on the host itself, so the guest scripts behind the file tools run for
/// real against temporary files. The host is macOS, which the macOS guest scripts expect; the
/// Linux ones are POSIX enough to run here too.
///
/// Copied from TarteletteGuestTests (there is no shared test-support target), without the stream
/// loss simulation.
final class LocalTransport: GuestTransport, Sendable {
  let label = "local"
  /// Variables merged over the test process environment (e.g. TMPDIR).
  let environment: [String: String]
  private let recorded = OSAllocatedUnfairLock(initialState: [[String]]())

  init(environment: [String: String] = [:]) {
    self.environment = environment
  }

  /// Every command run, oldest first.
  var commands: [[String]] { recorded.withLock { $0 } }

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    recorded.withLock { $0.append(command) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-local-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdinURL = directory.appendingPathComponent("stdin")
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    try (standardInput ?? Data()).write(to: stdinURL)
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    }
    process.standardInput = try FileHandle(forReadingFrom: stdinURL)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    process.standardOutput = stdout
    process.standardError = stderr

    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    try stdout.close()
    try stderr.close()
    return CommandOutput(
      status: status, stdout: try Data(contentsOf: stdoutURL), stderr: try Data(contentsOf: stderrURL))
  }
}
