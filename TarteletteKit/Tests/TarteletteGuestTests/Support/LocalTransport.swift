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
  /// Variables merged over the test process environment (e.g. HOME, PATH for fake tools).
  let environment: [String: String]
  private let lock = NSLock()
  private var _corruptedStreams = 0
  private var _commands: [[String]] = []

  init(label: String = "local", simulatesStreamLoss: Bool = false, environment: [String: String] = [:]) {
    self.label = label
    self.simulatesStreamLoss = simulatesStreamLoss
    self.environment = environment
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
    if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment
        .filter { $0.key != "WAYLAND_DISPLAY" }
        .merging(environment) { $1 }
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
    let output = try Data(contentsOf: stdoutURL)
    return CommandOutput(status: status, stdout: damaged(output), stderr: try Data(contentsOf: stderrURL))
  }
}

/// Wraps another transport to simulate an unreachable guest, slow transfers or failing commands,
/// and measures how many transfer ("heavy") commands overlap. Probes and change-count polls are
/// not heavy.
final class ControllableTransport: GuestTransport, @unchecked Sendable {
  let label = "controllable"
  private let inner: any GuestTransport
  private let lock = NSLock()
  private var _isReachable = true
  private var _heavyDelay: Duration = .zero
  private var _inFlight = 0
  private var _maxInFlight = 0
  private var _heavyCount = 0
  private var _failWhen: (@Sendable ([String]) -> Bool)?
  private var _unreachableWhen: (@Sendable ([String]) -> Bool)?

  init(wrapping inner: any GuestTransport) {
    self.inner = inner
  }

  var isReachable: Bool {
    get { lock.withLock { _isReachable } }
    set { lock.withLock { _isReachable = newValue } }
  }
  var heavyDelay: Duration {
    get { lock.withLock { _heavyDelay } }
    set { lock.withLock { _heavyDelay = newValue } }
  }
  var failWhen: (@Sendable ([String]) -> Bool)? {
    get { lock.withLock { _failWhen } }
    set { lock.withLock { _failWhen = newValue } }
  }
  /// Commands for which the guest is reported unreachable (as `tart exec` prints it), while other
  /// commands still go through.
  var unreachableWhen: (@Sendable ([String]) -> Bool)? {
    get { lock.withLock { _unreachableWhen } }
    set { lock.withLock { _unreachableWhen = newValue } }
  }
  var maxConcurrentHeavyCommands: Int { lock.withLock { _maxInFlight } }
  var heavyCommandCount: Int { lock.withLock { _heavyCount } }

  static func isPolling(_ command: [String]) -> Bool {
    command.first == "/usr/bin/env" || command.contains { $0.contains("emit({ changeCount: Number(board(argv[0]).changeCount) })") }
  }

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    guard isReachable else {
      return CommandOutput(
        status: 1,
        stderr: Data("Failed to connect to the VM using its control socket: x, is the Tart Guest Agent running?".utf8))
    }
    if let unreachableWhen, unreachableWhen(command) {
      return CommandOutput(
        status: 1,
        stderr: Data("Failed to connect to the VM using its control socket: x, is the Tart Guest Agent running?".utf8))
    }
    if let failWhen, failWhen(command) {
      return CommandOutput(status: 1, stderr: Data("simulated failure".utf8))
    }
    guard !Self.isPolling(command) else { return try await inner.run(command, standardInput: standardInput, timeout: timeout) }
    let delay = lock.withLock {
      _inFlight += 1
      _heavyCount += 1
      _maxInFlight = max(_maxInFlight, _inFlight)
      return _heavyDelay
    }
    defer { lock.withLock { _inFlight -= 1 } }
    if delay > .zero { try? await Task.sleep(for: delay) }
    return try await inner.run(command, standardInput: standardInput, timeout: timeout)
  }
}

/// A fake Linux desktop clipboard: an `xclip` look-alike that keeps one owner's targets as files,
/// so the Linux guest scripts run for real on this Mac.
struct FakeLinuxClipboard {
  let root: URL
  let bin: URL
  let store: URL
  let home: URL

  static let xclip = #"""
    #!/bin/sh
    d="$FAKE_CLIP"; t=text/plain; mode=o
    while [ $# -gt 0 ]; do
      case "$1" in
        -selection) shift ;;
        -t) shift; t="$1" ;;
        -i) mode=i ;;
        -o) mode=o ;;
      esac
      shift
    done
    if [ "$t" = TARGETS ]; then
      for f in "$d"/*; do [ -e "$f" ] && basename "$f" | sed 's#__#/#'; done
      exit 0
    fi
    f="$d/$(printf '%s' "$t" | sed 's#/#__#')"
    if [ "$mode" = i ]; then rm -f "$d"/*; cat > "$f"; else [ -f "$f" ] && cat "$f"; fi
    exit 0
    """#

  init() throws {
    root = try TestFiles.temporaryDirectory("tartelette-linux")
    bin = root.appendingPathComponent("bin", isDirectory: true)
    store = root.appendingPathComponent("clipboard", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    for directory in [bin, store, home] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let tool = bin.appendingPathComponent("xclip")
    try Data(Self.xclip.utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
  }

  var environment: [String: String] {
    ["PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_CLIP": store.path, "HOME": home.path]
  }

  func transport() -> LocalTransport { LocalTransport(label: "linux", environment: environment) }

  /// Contents of one clipboard target, e.g. `text/plain`.
  func target(_ mime: String) -> Data? {
    try? Data(contentsOf: store.appendingPathComponent(mime.replacingOccurrences(of: "/", with: "__")))
  }

  var targets: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [])
      .map { $0.replacingOccurrences(of: "__", with: "/") }.sorted()
  }

  /// Replaces the clipboard as another application would.
  func own(_ mime: String, _ data: Data) throws {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [] {
      try? FileManager.default.removeItem(at: store.appendingPathComponent(name))
    }
    try data.write(to: store.appendingPathComponent(mime.replacingOccurrences(of: "/", with: "__")))
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }
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
