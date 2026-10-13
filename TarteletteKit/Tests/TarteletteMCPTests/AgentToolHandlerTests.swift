import Foundation
import MCP
import Testing

@testable import TarteletteAgents
@testable import TarteletteMCP

@Suite("Agent tool handler: dispatch and results")
struct AgentToolHandlerTests {
  static let dispatchCases: [(tool: String, arguments: [String: Value], expected: FakeToolbox.Call)] = [
    ("list_vms", [:], .listVMs),
    ("vm_info", ["name": "dev"], .vmInfo(name: "dev")),
    ("start_vm", ["name": "dev"], .startVM(name: "dev", wait: false, timeout: nil)),
    ("start_vm", ["name": "dev", "wait": true, "timeout_seconds": 30], .startVM(name: "dev", wait: true, timeout: 30)),
    ("stop_vm", ["name": "dev"], .stopVM(name: "dev", force: false, timeout: nil)),
    ("stop_vm", ["name": "dev", "force": true, "timeout_seconds": 5], .stopVM(name: "dev", force: true, timeout: 5)),
    ("create_sandbox", ["template": "base"], .createSandbox(source: "base", name: nil, start: false)),
    (
      "create_sandbox", ["template": "base", "name": "box", "start": true],
      .createSandbox(source: "base", name: "box", start: true)
    ),
    ("delete_vm", ["name": "box"], .deleteVM(name: "box")),
    ("exec", ["name": "dev", "command": "uname -a"], .exec(name: "dev", command: "uname -a", stdin: nil, timeout: nil)),
    (
      "exec", ["name": "dev", "command": "cat", "stdin": "hello", "timeout_seconds": 9],
      .exec(name: "dev", command: "cat", stdin: "hello", timeout: 9)
    ),
    (
      "read_file", ["name": "dev", "path": "/etc/hosts"],
      .readFile(name: "dev", path: "/etc/hosts", offset: 0, length: nil)
    ),
    (
      "read_file", ["name": "dev", "path": "/etc/hosts", "offset": 10, "length": 20],
      .readFile(name: "dev", path: "/etc/hosts", offset: 10, length: 20)
    ),
    (
      "write_file", ["name": "dev", "path": "/tmp/a", "content": "hi"],
      .writeFile(name: "dev", path: "/tmp/a", content: "hi", encoding: .utf8, createDirectories: true)
    ),
    (
      "write_file",
      ["name": "dev", "path": "/tmp/a", "content": "aGk=", "encoding": "base64", "create_directories": false],
      .writeFile(name: "dev", path: "/tmp/a", content: "aGk=", encoding: .base64, createDirectories: false)
    ),
  ]

  @Test(arguments: dispatchCases)
  func dispatchesEachToolToTheToolbox(tool: String, arguments: [String: Value], expected: FakeToolbox.Call)
    async throws
  {
    let toolbox = FakeToolbox()
    let result = try await AgentToolHandler { toolbox }.call(tool, arguments: arguments)

    #expect(toolbox.calls == [expected])
    #expect(result.isError != true)
  }

  @Test func returnsTheResultAsCompactJSONWithSortedKeys() async throws {
    let result = try await AgentToolHandler { FakeToolbox() }.call("list_vms", arguments: nil)

    let json =
      #"{"vms":[{"access":"operate","createdByAgent":false,"diskGB":50,"name":"dev","os":"Linux","state":"stopped"}]}"#
    #expect(result.content == [.text(text: json, annotations: nil, _meta: nil)])
    #expect(result.isError != true)
  }

  @Test func alsoReturnsTheResultAsStructuredContent() async throws {
    let result = try await AgentToolHandler { FakeToolbox() }.call(
      "write_file", arguments: ["name": "dev", "path": "/home/admin/a.txt", "content": "hi"])

    let json = #"{"bytesWritten":2,"path":"/home/admin/a.txt","sha256":"8f43"}"#
    #expect(result.content == [.text(text: json, annotations: nil, _meta: nil)])
    #expect(result.structuredContent == ["bytesWritten": 2, "path": "/home/admin/a.txt", "sha256": "8f43"])
  }
}
