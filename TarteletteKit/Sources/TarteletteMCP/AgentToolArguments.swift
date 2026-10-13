import Foundation
import MCP
import TarteletteAgents

/// Why a tool call's arguments don't match the tool's input schema, phrased for the agent.
enum AgentArgumentError: Error, Equatable, LocalizedError {
  case unknown(argument: String, tool: AgentTool, accepted: [String])
  case missing(argument: String, tool: AgentTool)
  case wrongType(argument: String, tool: AgentTool, expected: String, actual: String)
  case notOneOf(argument: String, tool: AgentTool, allowed: [String], actual: String)
  /// The MCP SDK decodes strings shaped like data URLs (`data:…,…`) into bytes it can't turn back
  /// into the original text, so such a string can't be passed on unchanged.
  case dataURL(argument: String, tool: AgentTool)

  var errorDescription: String? {
    switch self {
    case .unknown(let argument, let tool, let accepted):
      "Unknown argument “\(argument.prefix(80))” for \(tool.rawValue). "
        + (accepted.isEmpty ? "It takes no arguments." : "It takes: \(accepted.joined(separator: ", ")).")
    case .missing(let argument, let tool):
      "Missing required argument “\(argument)” for \(tool.rawValue)."
    case .wrongType(let argument, let tool, let expected, let actual):
      "Argument “\(argument)” of \(tool.rawValue) must be \(Self.article(expected)) \(expected), "
        + "not \(Self.article(actual)) \(actual)."
    case .notOneOf(let argument, let tool, let allowed, let actual):
      "Argument “\(argument)” of \(tool.rawValue) must be "
        + allowed.map { "“\($0)”" }.joined(separator: " or ") + ", not “\(actual.prefix(80))”."
    case .dataURL(let argument, let tool):
      "Argument “\(argument)” of \(tool.rawValue) starts with “data:” and contains a comma, so it arrives as a "
        + "data URL that can't be passed on unchanged."
        + (tool == .writeFile && argument == "content"
          ? " Send the content base64-encoded with encoding “base64”." : "")
    }
  }

  private static func article(_ typeName: String) -> String {
    ["a", "e", "i", "o", "u"].contains(typeName.prefix(1)) ? "an" : "a"
  }
}

/// A tool call's arguments, checked against the tool's parameters: no unknown arguments, every
/// required one present, and each of the declared type. A JSON null counts as absent.
struct AgentToolArguments {
  private enum Argument {
    case string(String)
    case integer(Int)
    case boolean(Bool)
  }

  let tool: AgentTool
  private let values: [String: Argument]

  init(_ arguments: [String: Value]?, for definition: AgentToolDefinition) throws(AgentArgumentError) {
    tool = definition.tool
    let present = (arguments ?? [:]).filter { !$0.value.isNull }
    let accepted = definition.parameters.map(\.name)
    if let unknown = present.keys.sorted().first(where: { !accepted.contains($0) }) {
      throw .unknown(argument: unknown, tool: tool, accepted: accepted)
    }
    var values: [String: Argument] = [:]
    for parameter in definition.parameters {
      guard let value = present[parameter.name] else {
        if parameter.required { throw .missing(argument: parameter.name, tool: tool) }
        continue
      }
      values[parameter.name] = try Self.argument(value, for: parameter, tool: tool)
    }
    self.values = values
  }

  private static func argument(_ value: Value, for parameter: AgentToolParameter, tool: AgentTool)
    throws(AgentArgumentError) -> Argument
  {
    let mismatch = AgentArgumentError.wrongType(
      argument: parameter.name, tool: tool, expected: parameter.typeName, actual: typeName(of: value))
    switch (parameter.kind, value) {
    case (.string, .string(let text)):
      return .string(text)
    case (.oneOf(let allowed), .string(let text)):
      guard allowed.contains(text) else {
        throw .notOneOf(argument: parameter.name, tool: tool, allowed: allowed, actual: text)
      }
      return .string(text)
    case (.string, .data), (.oneOf, .data):
      throw .dataURL(argument: parameter.name, tool: tool)
    case (.integer, .int(let number)):
      return .integer(number)
    case (.integer, .double(let number)):
      // Some clients send every number as a double; whole numbers are fine.
      guard number.rounded() == number, let integer = Int(exactly: number) else { throw mismatch }
      return .integer(integer)
    case (.boolean, .bool(let flag)):
      return .boolean(flag)
    default:
      throw mismatch
    }
  }

  private static func typeName(of value: Value) -> String {
    switch value {
    case .null: "null"
    case .bool: "boolean"
    case .int: "integer"
    case .double: "number"
    case .string, .data: "string"
    case .array: "array"
    case .object: "object"
    }
  }

  func string(_ name: String) -> String? {
    guard case .string(let text)? = values[name] else { return nil }
    return text
  }

  func integer(_ name: String) -> Int? {
    guard case .integer(let number)? = values[name] else { return nil }
    return number
  }

  func boolean(_ name: String) -> Bool? {
    guard case .boolean(let flag)? = values[name] else { return nil }
    return flag
  }

  /// A required string argument (`init` already checked that it is there).
  func requiredString(_ name: String) throws(AgentArgumentError) -> String {
    guard let text = string(name) else { throw .missing(argument: name, tool: tool) }
    return text
  }
}
