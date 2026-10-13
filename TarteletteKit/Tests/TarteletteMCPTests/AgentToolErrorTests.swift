import Foundation
import MCP
import Testing

@testable import TarteletteAgents
@testable import TarteletteMCP

@Suite("Agent tool handler: invalid arguments and errors")
struct AgentToolErrorTests {
  static let invalidArguments: [(tool: String, arguments: [String: Value]?, message: String)] = [
    ("vm_info", nil, "Missing required argument “name” for vm_info."),
    ("exec", ["name": "dev"], "Missing required argument “command” for exec."),
    ("vm_info", ["name": 5], "Argument “name” of vm_info must be a string, not an integer."),
    ("start_vm", ["name": "dev", "wait": "yes"], "Argument “wait” of start_vm must be a boolean, not a string."),
    (
      "exec", ["name": "dev", "command": "ls", "timeout_seconds": 1.5],
      "Argument “timeout_seconds” of exec must be an integer, not a number."
    ),
    (
      "write_file", ["name": "dev", "path": "/tmp/a", "content": "hi", "encoding": "latin1"],
      "Argument “encoding” of write_file must be “utf8” or “base64”, not “latin1”."
    ),
    (
      "start_vm", ["name": "dev", "timeout": 5],
      "Unknown argument “timeout” for start_vm. It takes: name, wait, timeout_seconds."
    ),
    ("list_vms", ["all": true], "Unknown argument “all” for list_vms. It takes no arguments."),
    (
      "write_file", ["name": "dev", "path": "/tmp/a", "content": .data(mimeType: "text/plain", Data("x".utf8))],
      "Argument “content” of write_file starts with “data:” and contains a comma, so it arrives as a data URL "
        + "that can't be passed on unchanged. Send the content base64-encoded with encoding “base64”."
    ),
  ]

  @Test(arguments: invalidArguments)
  func reportsInvalidArgumentsToTheAgentWithoutCallingTheToolbox(
    tool: String, arguments: [String: Value]?, message: String
  ) async throws {
    let toolbox = FakeToolbox()
    let result = try await AgentToolHandler { toolbox }.call(tool, arguments: arguments)

    #expect(result.isError == true)
    #expect(result.content == [.text(text: message, annotations: nil, _meta: nil)])
    #expect(toolbox.calls.isEmpty)
  }

  @Test func acceptsWholeNumbersSentAsDoublesAndTreatsNullAsAbsent() async throws {
    let toolbox = FakeToolbox()
    let result = try await AgentToolHandler { toolbox }.call(
      "start_vm", arguments: ["name": "dev", "wait": .null, "timeout_seconds": 30.0])

    #expect(result.isError != true)
    #expect(toolbox.calls == [.startVM(name: "dev", wait: false, timeout: 30)])
  }

  @Test func rejectsUnknownToolsAsAProtocolError() async throws {
    await #expect(throws: MCPError.invalidParams("Unknown tool: format_disk")) {
      try await AgentToolHandler { FakeToolbox() }.call("format_disk", arguments: nil)
    }
  }

  static let toolErrors: [(error: any Error & Sendable, message: String)] = [
    (AgentDenial.agentsDisabled, "Agent access is turned off. Turn it on in Tartelette › Settings › Agents."),
    (
      AgentDenial.notShared(vm: "dev", operation: .exec),
      "VM “dev” isn't shared with agents. In Tartelette, set its agent access to Operate."
    ),
    (
      AgentToolError.vmNotRunning("dev"), "VM “dev” isn't running. Start it with start_vm."
    ),
    (
      AgentToolError.settingsUnreadable(detail: "bad JSON"),
      "Tartelette's agent settings couldn't be read, so agent access is refused. "
        + "Check them in Tartelette › Settings › Agents. (bad JSON)"
    ),
    (AgentFileError.invalidBase64, "The content isn't valid base64."),
  ]

  @Test(arguments: 0..<toolErrors.count)
  func returnsToolErrorsAsErrorResults(index: Int) async throws {
    let (error, message) = Self.toolErrors[index]
    let result = try await AgentToolHandler { FakeToolbox(error: error) }.call(
      "exec", arguments: ["name": "dev", "command": "ls"])

    #expect(result.isError == true)
    #expect(result.content == [.text(text: message, annotations: nil, _meta: nil)])
  }

  @Test func reportsAMissingTartForEveryTool() async throws {
    let handler = AgentToolHandler { throw AgentToolError.tartNotFound }
    let result = try await handler.call("list_vms", arguments: nil)

    #expect(result.isError == true)
    guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text content"); return }
    #expect(text.hasPrefix("Tartelette couldn't find the tart executable. Install Tart"))
  }

  @Test func letsCancellationThrough() async throws {
    await #expect(throws: CancellationError.self) {
      try await AgentToolHandler { FakeToolbox(error: CancellationError()) }.call("list_vms", arguments: nil)
    }
  }

  @Test func leavesOutStructuredContentTheSDKWouldAlter() async throws {
    let toolbox = FakeToolbox(readContent: "data:a,b")
    let result = try await AgentToolHandler { toolbox }.call("read_file", arguments: ["name": "dev", "path": "/a"])

    #expect(result.structuredContent == nil)
    guard case .text(let text, _, _)? = result.content.first else { Issue.record("no text content"); return }
    #expect(text.contains(#""content":"data:a,b""#))
  }
}
