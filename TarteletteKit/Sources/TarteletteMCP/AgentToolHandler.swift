import Foundation
import MCP
import TarteletteAgents

/// What `list_vms` returns: structured content has to be a JSON object, so the list is wrapped.
struct AgentVMList: Codable, Sendable, Equatable {
  var vms: [AgentVMSummary]
}

/// Runs `tools/call` requests: checks the arguments, calls the toolbox and returns its result as
/// compact JSON with sorted keys.
///
/// Failures the agent can act on (refusals by the user's settings, tool errors, unreadable
/// settings, a missing Tart, invalid arguments) come back as tool results with `isError` set and
/// the message as text, so the agent reads them; only an unknown tool is a protocol error.
public struct AgentToolHandler: Sendable {
  /// Builds the toolbox for one call. Throwing (e.g. `AgentToolError.tartNotFound`) fails the call.
  public typealias ToolboxFactory = @Sendable () throws -> any AgentToolProviding

  let makeToolbox: ToolboxFactory

  public init(makeToolbox: @escaping ToolboxFactory) {
    self.makeToolbox = makeToolbox
  }

  /// Runs one tool call.
  ///
  /// - Throws: `MCPError.invalidParams` for a tool that doesn't exist, `CancellationError` when
  ///   the call was cancelled.
  public func call(_ name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
    guard let tool = AgentTool(rawValue: name) else { throw MCPError.invalidParams("Unknown tool: \(name)") }
    do {
      let arguments = try AgentToolArguments(arguments, for: AgentToolCatalog.definition(for: tool))
      return try Self.result(try await run(tool, arguments, on: try makeToolbox()))
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      return CallTool.Result(
        content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
    }
  }

  private func run(_ tool: AgentTool, _ arguments: AgentToolArguments, on toolbox: any AgentToolProviding)
    async throws -> any Encodable
  {
    switch tool {
    case .listVMs:
      return AgentVMList(vms: try await toolbox.listVMs())
    case .vmInfo:
      return try await toolbox.vmInfo(name: try arguments.requiredString("name"))
    case .startVM:
      return try await toolbox.startVM(
        name: try arguments.requiredString("name"), wait: arguments.boolean("wait") ?? false,
        timeout: arguments.integer("timeout_seconds"))
    case .stopVM:
      return try await toolbox.stopVM(
        name: try arguments.requiredString("name"), force: arguments.boolean("force") ?? false,
        timeout: arguments.integer("timeout_seconds"))
    case .createSandbox:
      return try await toolbox.createSandbox(
        from: try arguments.requiredString("template"), name: arguments.string("name"),
        start: arguments.boolean("start") ?? false, progress: nil)
    case .deleteVM:
      return try await toolbox.deleteVM(name: try arguments.requiredString("name"))
    case .exec:
      return try await toolbox.exec(
        name: try arguments.requiredString("name"), command: try arguments.requiredString("command"),
        standardInput: arguments.string("stdin"), timeout: arguments.integer("timeout_seconds"))
    case .readFile:
      return try await toolbox.readFile(
        name: try arguments.requiredString("name"), path: try arguments.requiredString("path"),
        offset: arguments.integer("offset") ?? 0, length: arguments.integer("length"))
    case .writeFile:
      return try await toolbox.writeFile(
        name: try arguments.requiredString("name"), path: try arguments.requiredString("path"),
        content: try arguments.requiredString("content"),
        encoding: arguments.string("encoding").flatMap(AgentFileEncoding.init(rawValue:)) ?? .utf8,
        createDirectories: arguments.boolean("create_directories") ?? true)
    }
  }

  /// The value as compact, key-sorted JSON text, and as structured content when the SDK can pass
  /// it on unchanged: it re-decodes results, turning strings shaped like data URLs (`data:…,…`)
  /// into bytes, so a result holding such a string is sent as text only.
  static func result(_ value: any Encodable) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    let decoded = try JSONDecoder().decode(Value.self, from: data)
    // `.none`, not `nil`: `Value` is ExpressibleByNilLiteral, so `nil` would become `Value.null`.
    let structured: Value? = decoded.containsData ? .none : .some(decoded)
    return CallTool.Result(
      content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
      structuredContent: structured,
      isError: false)
  }
}

extension Value {
  /// Whether the value is, or holds, `.data`.
  fileprivate var containsData: Bool {
    switch self {
    case .data: true
    case .array(let values): values.contains { $0.containsData }
    case .object(let values): values.values.contains { $0.containsData }
    default: false
    }
  }
}
