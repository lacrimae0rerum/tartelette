import Foundation
import TarteletteCore

@testable import TarteletteGuest

/// Runs "guest" commands on the host itself. The host is macOS, so the macOS guest scripts run
/// for real (against private named pasteboards and temporary staging folders).
///
/// With `simulatesStreamLoss`, it imitates tart #1347: any stream above 256 KiB (stdin or stdout)
/// silently loses a 64 KiB block, while the command still exits 0.
final class LocalTransport: GuestTransport, @unchecked Sendable {
  let label: String
  let simulatesStreamLoss: Bool
  private let lock = NSLock()
  private var _corruptedStreams = 0
  private var _commands: [[String]] = []

  init(label: String = "local", simulatesStreamLoss: Bool = false) {
    self.label = label
    self.simulatesStreamLoss = simulatesStreamLoss
  }

  var corruptedStreams: Int { lock.withLock { _corruptedStreams } }
  var commands: [[String]] { lock.withLock { _commands } }

  static let lossThreshold = 256 * 1024
  static let lostBlock = 64 * 1024

  private func damaged(_ data: Data) -> Data {
    guard simulatesStreamLoss, data.count > Self.lossThreshold else { return data }
    lock.withLock { _corruptedStreams += 1 }
    var copy = data
    copy.removeSubrange((copy.startIndex + 128 * 1024)..<(copy.startIndex + 128 * 1024 + Self.lostBlock))
    return copy
  }

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    lock.withLock { _commands.append(command) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-local-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdinURL = directory.appendingPathComponent("stdin")
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    try damaged(standardInput ?? Data()).write(to: stdinURL)
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
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
    let output = try Data(contentsOf: stdoutURL)
    return CommandOutput(status: status, stdout: damaged(output), stderr: try Data(contentsOf: stderrURL))
  }
}

/// A transport with canned replies.
struct ScriptedTransport: GuestTransport {
  var label = "scripted"
  var reply: @Sendable ([String], Data?) throws -> CommandOutput

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    try reply(command, standardInput)
  }
}

/// Records process requests instead of running them.
final class RecordingRunner: ProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [ProcessRequest] = []
  var output = CommandOutput(status: 0)

  var requests: [ProcessRequest] { lock.withLock { _requests } }

  func run(_ request: ProcessRequest) async throws -> CommandOutput {
    lock.withLock { _requests.append(request) }
    return output
  }
}

enum TestFiles {
  static func temporaryDirectory(_ name: String = "tartelette-guest-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Deterministic pseudo-random bytes (incompressible enough to defeat gzip).
  static func noise(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
    var state = seed
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
      for index in 0..<count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        buffer[index] = UInt8(truncatingIfNeeded: state)
      }
    }
    return data
  }
}
