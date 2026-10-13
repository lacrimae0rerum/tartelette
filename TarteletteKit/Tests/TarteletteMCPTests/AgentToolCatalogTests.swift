import MCP
import Testing

@testable import TarteletteAgents
@testable import TarteletteMCP

@Suite("Agent tool catalog")
struct AgentToolCatalogTests {
  @Test func listsExactlyTheAgentTools() {
    #expect(AgentToolCatalog.tools.map(\.name) == AgentTool.allCases.map(\.rawValue))
  }

  @Test func declaresRequiredArgumentsAndTypes() throws {
    let expected: [String: (required: [String], types: [String: String])] = [
      "list_vms": ([], [:]),
      "vm_info": (["name"], ["name": "string"]),
      "start_vm": (["name"], ["name": "string", "wait": "boolean", "timeout_seconds": "integer"]),
      "stop_vm": (["name"], ["name": "string", "force": "boolean", "timeout_seconds": "integer"]),
      "create_sandbox": (["template"], ["template": "string", "name": "string", "start": "boolean"]),
      "delete_vm": (["name"], ["name": "string"]),
      "exec": (
        ["name", "command"],
        ["name": "string", "command": "string", "stdin": "string", "timeout_seconds": "integer"]
      ),
      "read_file": (
        ["name", "path"], ["name": "string", "path": "string", "offset": "integer", "length": "integer"]
      ),
      "write_file": (
        ["name", "path", "content"],
        [
          "name": "string", "path": "string", "content": "string", "encoding": "string",
          "create_directories": "boolean",
        ]
      ),
    ]
    for tool in AgentToolCatalog.tools {
      let schema = try #require(tool.inputSchema.objectValue)
      let want = try #require(expected[tool.name], "unexpected tool \(tool.name)")
      #expect(schema["type"] == "object")
      #expect(schema["additionalProperties"] == false, "\(tool.name)")
      let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
      #expect(required == want.required, "\(tool.name)")
      let properties = try #require(schema["properties"]?.objectValue)
      let types = properties.mapValues { $0.objectValue?["type"]?.stringValue ?? "" }
      #expect(types == want.types, "\(tool.name)")
      #expect(properties.values.allSatisfy { $0.objectValue?["description"]?.stringValue?.isEmpty == false })
      #expect(tool.description?.isEmpty == false)
    }
  }

  @Test func limitsTheFileEncodingToItsTwoValues() throws {
    let writeFile = try #require(AgentToolCatalog.tools.first { $0.name == "write_file" })
    let encoding = writeFile.inputSchema.objectValue?["properties"]?.objectValue?["encoding"]?.objectValue
    #expect(encoding?["enum"] == ["utf8", "base64"])
  }

  @Test func marksReadOnlyAndDestructiveTools() {
    let annotations = Dictionary(uniqueKeysWithValues: AgentToolCatalog.tools.map { ($0.name, $0.annotations) })
    for name in ["list_vms", "vm_info", "read_file"] {
      #expect(annotations[name]?.readOnlyHint == true, "\(name)")
    }
    for name in ["delete_vm", "write_file", "exec", "stop_vm"] {
      #expect(annotations[name]?.readOnlyHint == false, "\(name)")
      #expect(annotations[name]?.destructiveHint == true, "\(name)")
    }
  }
}
