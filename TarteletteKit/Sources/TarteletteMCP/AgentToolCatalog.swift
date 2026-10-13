import Foundation
import MCP
import TarteletteAgents

/// One argument of an agent tool, as its input schema declares it and as calls are checked against.
struct AgentToolParameter: Sendable {
  enum Kind: Sendable, Equatable {
    case string
    case integer
    case boolean
    /// A string limited to these values.
    case oneOf([String])
  }

  let name: String
  let kind: Kind
  let required: Bool
  let description: String

  static func required(_ name: String, _ kind: Kind, _ description: String) -> AgentToolParameter {
    AgentToolParameter(name: name, kind: kind, required: true, description: description)
  }

  static func optional(_ name: String, _ kind: Kind, _ description: String) -> AgentToolParameter {
    AgentToolParameter(name: name, kind: kind, required: false, description: description)
  }

  /// The JSON Schema type name, also used in argument error messages.
  var typeName: String {
    switch kind {
    case .string, .oneOf: "string"
    case .integer: "integer"
    case .boolean: "boolean"
    }
  }

  var schema: Value {
    var schema: [String: Value] = ["type": .string(typeName), "description": .string(description)]
    if case .oneOf(let values) = kind { schema["enum"] = .array(values.map(Value.string)) }
    return .object(schema)
  }
}

/// An agent tool as the MCP server lists it: what it does, for an agent, and the arguments it takes.
struct AgentToolDefinition: Sendable {
  let tool: AgentTool
  let title: String
  let description: String
  let parameters: [AgentToolParameter]
  /// Whether the tool only reads; otherwise it may change or destroy what it acts on.
  let readOnly: Bool

  var mcpTool: Tool {
    Tool(
      name: tool.rawValue,
      title: title,
      description: description,
      inputSchema: .object([
        "type": "object",
        "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })),
        "required": .array(parameters.filter(\.required).map { .string($0.name) }),
        "additionalProperties": false,
      ]),
      annotations: Tool.Annotations(
        title: title, readOnlyHint: readOnly, destructiveHint: readOnly ? nil : destructive, openWorldHint: false))
  }

  /// Starting a VM or creating a sandbox only adds; the other changing tools can lose data.
  private var destructive: Bool { tool != .startVM && tool != .createSandbox }
}

/// The agent tools the MCP server exposes, in `AgentTool` order.
public enum AgentToolCatalog {
  /// The tools as `tools/list` reports them.
  public static var tools: [Tool] { AgentTool.allCases.map { definition(for: $0).mcpTool } }

  private static let vmName = AgentToolParameter.required("name", .string, "The VM's name, as list_vms reports it.")
  private static let operateAccess = "Needs operate access, or a VM created by an agent."

  static func definition(for tool: AgentTool) -> AgentToolDefinition {
    switch tool {
    case .listVMs:
      AgentToolDefinition(
        tool: tool, title: "List VMs",
        description: """
          Lists the local Tart VMs the user shared with agents in Tartelette, with each VM's state \
          (running, stopped or suspended), OS, disk size and access level: read (inspect only), operate \
          (start, stop, exec, read and write files), template (inspect, and clone with create_sandbox) or \
          owned (created by an agent: everything, including delete_vm). VMs the user didn't share aren't \
          listed. Call this first.
          """,
        parameters: [], readOnly: true)
    case .vmInfo:
      AgentToolDefinition(
        tool: tool, title: "VM details",
        description: """
          Shows one VM's state, OS, access level, CPU count, memory, display size and, while it runs, its \
          IP address. Needs read access or higher.
          """,
        parameters: [vmName], readOnly: true)
    case .startVM:
      AgentToolDefinition(
        tool: tool, title: "Start VM",
        description: """
          Starts a VM headless (without a window) in the background; a running VM is left as it is. Pass \
          wait: true to wait until the Tart Guest Agent in the VM answers, so exec and the file tools work \
          right away. macOS limits how many macOS VMs can run at the same time. \(operateAccess)
          """,
        parameters: [
          vmName,
          .optional("wait", .boolean, "Wait until the VM's guest agent answers. Defaults to false."),
          .optional(
            "timeout_seconds", .integer,
            "How long to wait, in seconds. Defaults to \(AgentToolbox.defaultStartTimeoutSeconds), "
              + "at most \(AgentToolbox.maxStartTimeoutSeconds)."),
        ],
        readOnly: false)
    case .stopVM:
      AgentToolDefinition(
        tool: tool, title: "Stop VM",
        description: """
          Stops a VM: asks the guest OS to shut down, and powers the VM off if it hasn't stopped in time. \
          Pass force: true to power it off at once, which can lose unsaved work in the guest. \
          \(operateAccess)
          """,
        parameters: [
          vmName,
          .optional("force", .boolean, "Power the VM off at once instead of shutting it down. Defaults to false."),
          .optional(
            "timeout_seconds", .integer,
            "Seconds to wait for the shutdown before powering off. Defaults to "
              + "\(AgentToolbox.defaultStopTimeoutSeconds), at most \(AgentToolbox.maxStopTimeoutSeconds)."),
        ],
        readOnly: false)
    case .createSandbox:
      AgentToolDefinition(
        tool: tool, title: "Create sandbox VM",
        description: """
          Creates a disposable VM by cloning a stopped VM the user shared as template. The new VM belongs \
          to agents: they can start and stop it, run commands, read and write its files, and delete it \
          with delete_vm. The user's settings limit how many agent VMs may exist \
          (\(AgentLimits.defaultMaxAgentVMs) by default). Cloning can take a while; progress is reported \
          when the client asks for it. Returns the new VM's summary.
          """,
        parameters: [
          .required("template", .string, "The VM to clone: a stopped VM shared as template."),
          .optional(
            "name", .string,
            "The new VM's name: 1 to 64 letters, digits, “.”, “_” or “-”, starting with a letter or digit. "
              + "Defaults to “<template>-agent-<4 hex digits>”."),
          .optional(
            "start", .boolean,
            "Start the new VM right away, without waiting for its guest agent (start_vm with wait: true "
              + "waits). Defaults to false."),
        ],
        readOnly: false)
    case .deleteVM:
      AgentToolDefinition(
        tool: tool, title: "Delete agent VM",
        description: """
          Deletes a VM an agent created with create_sandbox, powering it off first if it is running. VMs \
          the user shared can't be deleted. This can't be undone.
          """,
        parameters: [vmName], readOnly: false)
    case .exec:
      AgentToolDefinition(
        tool: tool, title: "Run command in VM",
        description: """
          Runs a shell command in a running VM through the Tart Guest Agent, as the guest's user in a login \
          shell (/bin/sh -lc), and returns its exit code, stdout and stderr. Each stream is cut to the \
          user's output limit (\(AgentLimits.defaultMaxOutputBytes / 1024) KiB by default); \
          stdoutTruncated and stderrTruncated tell when. Run long tasks in the background. \(operateAccess)
          """,
        parameters: [
          vmName,
          .required("command", .string, "A shell command line."),
          .optional("stdin", .string, "Text passed to the command's standard input."),
          .optional(
            "timeout_seconds", .integer,
            "Seconds the command may run. The default and maximum are the user's settings "
              + "(\(AgentLimits.defaultExecTimeoutSeconds) and \(AgentLimits.defaultExecTimeoutMaxSeconds) "
              + "by default)."),
        ],
        readOnly: false)
    case .readFile:
      AgentToolDefinition(
        tool: tool, title: "Read file from VM",
        description: """
          Reads part of a file in a running VM. Returns the bytes as UTF-8 text, or as base64 when they \
          aren't valid UTF-8 (see encoding), with the file's size and whether the end was reached. Reads \
          at most the user's output limit (\(AgentLimits.defaultMaxOutputBytes / 1024) KiB by default) per \
          call: page through big files with offset and length. \(operateAccess)
          """,
        parameters: [
          vmName,
          .required("path", .string, "The file's absolute path in the guest."),
          .optional("offset", .integer, "The first byte to read. Defaults to 0."),
          .optional("length", .integer, "How many bytes to read. Defaults to, and is capped at, the output limit."),
        ],
        readOnly: true)
    case .writeFile:
      AgentToolDefinition(
        tool: tool, title: "Write file to VM",
        description: """
          Writes a file in a running VM, replacing any file at the path. The transfer is verified with \
          SHA-256. The user's settings limit the size (\(AgentLimits.defaultMaxFileBytes / 1_048_576) MiB \
          by default). \(operateAccess)
          """,
        parameters: [
          vmName,
          .required("path", .string, "The file's absolute path in the guest."),
          .required("content", .string, "The file's content: UTF-8 text, or base64 with encoding “base64”."),
          .optional(
            "encoding", .oneOf(["utf8", "base64"]),
            "How content is encoded: “utf8” (the default) or “base64” for binary data."),
          .optional("create_directories", .boolean, "Create missing parent folders. Defaults to true."),
        ],
        readOnly: false)
    }
  }
}
