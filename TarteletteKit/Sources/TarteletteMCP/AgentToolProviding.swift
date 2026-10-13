import Foundation
import TarteletteAgents

/// The agent tool operations the MCP server dispatches to. `AgentToolbox` provides them; tests
/// substitute a fake.
public protocol AgentToolProviding: Sendable {
  func listVMs() async throws -> [AgentVMSummary]
  func vmInfo(name: String) async throws -> AgentVMDetails
  func startVM(name: String, wait: Bool, timeout: Int?) async throws -> AgentStartResult
  func stopVM(name: String, force: Bool, timeout: Int?) async throws -> AgentStopResult
  func createSandbox(
    from source: String,
    name: String?,
    start: Bool,
    progress: (@Sendable (Double) -> Void)?
  ) async throws -> AgentVMSummary
  func deleteVM(name: String) async throws -> AgentDeleteResult
  func exec(name: String, command: String, standardInput: String?, timeout: Int?) async throws -> AgentExecResult
  func readFile(name: String, path: String, offset: Int, length: Int?) async throws -> AgentReadFileResult
  func writeFile(
    name: String,
    path: String,
    content: String,
    encoding: AgentFileEncoding,
    createDirectories: Bool
  ) async throws -> AgentWriteFileResult
}

extension AgentToolbox: AgentToolProviding {}
