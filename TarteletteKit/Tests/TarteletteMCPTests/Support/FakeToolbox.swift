import Foundation
import TarteletteAgents
import TarteletteMCP

/// Records the toolbox calls the MCP layer makes and answers them with fixed results.
final class FakeToolbox: AgentToolProviding, @unchecked Sendable {
  enum Call: Equatable, Sendable {
    case listVMs
    case vmInfo(name: String)
    case startVM(name: String, wait: Bool, timeout: Int?)
    case stopVM(name: String, force: Bool, timeout: Int?)
    case createSandbox(source: String, name: String?, start: Bool)
    case deleteVM(name: String)
    case exec(name: String, command: String, stdin: String?, timeout: Int?)
    case readFile(name: String, path: String, offset: Int, length: Int?)
    case writeFile(name: String, path: String, content: String, encoding: AgentFileEncoding, createDirectories: Bool)
  }

  static let summary = AgentVMSummary(
    name: "dev", state: "stopped", os: "Linux", access: .operate, createdByAgent: false, diskGB: 50, sizeGB: nil)

  private let lock = NSLock()
  private var recorded: [Call] = []
  /// Thrown by every call instead of answering.
  let error: (any Error)?
  /// Reported through `createSandbox`'s progress handler before it returns.
  let cloneProgress: [Double]
  /// What `readFile` returns as the file's content.
  let readContent: String

  init(error: (any Error)? = nil, cloneProgress: [Double] = [], readContent: String = "hi") {
    self.error = error
    self.cloneProgress = cloneProgress
    self.readContent = readContent
  }

  var calls: [Call] { lock.withLock { recorded } }

  private func record(_ call: Call) throws {
    lock.withLock { recorded.append(call) }
    if let error { throw error }
  }

  func listVMs() async throws -> [AgentVMSummary] {
    try record(.listVMs)
    return [Self.summary]
  }

  func vmInfo(name: String) async throws -> AgentVMDetails {
    try record(.vmInfo(name: name))
    return AgentVMDetails(summary: Self.summary, cpuCount: 4, memoryMB: 8192, display: "1024x768", ipAddress: nil)
  }

  func startVM(name: String, wait: Bool, timeout: Int?) async throws -> AgentStartResult {
    try record(.startVM(name: name, wait: wait, timeout: timeout))
    return AgentStartResult(name: name, state: "running", alreadyRunning: false, guestAgentReady: wait ? true : nil)
  }

  func stopVM(name: String, force: Bool, timeout: Int?) async throws -> AgentStopResult {
    try record(.stopVM(name: name, force: force, timeout: timeout))
    return AgentStopResult(name: name, state: "stopped", method: force ? .powerOff : .guestShutdown)
  }

  func createSandbox(
    from source: String,
    name: String?,
    start: Bool,
    progress: (@Sendable (Double) -> Void)?
  ) async throws -> AgentVMSummary {
    try record(.createSandbox(source: source, name: name, start: start))
    for fraction in cloneProgress { progress?(fraction) }
    var summary = Self.summary
    summary.name = name ?? "\(source)-agent-0001"
    summary.access = .owned
    summary.createdByAgent = true
    return summary
  }

  func deleteVM(name: String) async throws -> AgentDeleteResult {
    try record(.deleteVM(name: name))
    return AgentDeleteResult(name: name, poweredOff: false)
  }

  func exec(name: String, command: String, standardInput: String?, timeout: Int?) async throws -> AgentExecResult {
    try record(.exec(name: name, command: command, stdin: standardInput, timeout: timeout))
    return AgentExecResult(
      exitCode: 0, stdout: "ok\n", stderr: "", stdoutTruncated: false, stderrTruncated: false, stdoutBytes: 3,
      stderrBytes: 0)
  }

  func readFile(name: String, path: String, offset: Int, length: Int?) async throws -> AgentReadFileResult {
    try record(.readFile(name: name, path: path, offset: offset, length: length))
    let length = readContent.utf8.count
    return AgentReadFileResult(
      path: path, content: readContent, encoding: .utf8, offset: offset, length: length, size: length, endOfFile: true)
  }

  func writeFile(
    name: String,
    path: String,
    content: String,
    encoding: AgentFileEncoding,
    createDirectories: Bool
  ) async throws -> AgentWriteFileResult {
    try record(
      .writeFile(name: name, path: path, content: content, encoding: encoding, createDirectories: createDirectories))
    return AgentWriteFileResult(path: path, bytesWritten: 2, sha256: "8f43")
  }
}
