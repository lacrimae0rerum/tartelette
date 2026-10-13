import Foundation
import SwiftUI
import TarteletteKit

/// How to register the bundled `tartelette-mcp` helper with an agent.
struct AgentSetup {
  let helperPath: String

  /// The helper inside this app's bundle, nil when the build doesn't include it.
  static var bundled: AgentSetup? {
    Bundle.main.url(forAuxiliaryExecutable: "tartelette-mcp").map { AgentSetup(helperPath: $0.path) }
  }

  /// Registers the helper with Claude Code.
  var claudeCommand: String {
    ShellQuoting.join(["claude", "mcp", "add", "tartelette", "--", helperPath])
  }

  /// The `mcpServers` entry most other MCP clients (Codex, Cursor…) accept.
  var mcpConfiguration: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let command = (try? encoder.encode(helperPath)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    return """
      {
        "mcpServers": {
          "tartelette": {
            "command": \(command)
          }
        }
      }
      """
  }
}

extension AgentAccess {
  var title: String { EffectiveAccess(self).title }

  /// What agents may do at this level, in a sentence.
  var summary: String {
    switch self {
    case .none: "Hidden from agents."
    case .read: "Agents can see the VM and its settings."
    case .operate: "Agents can start and stop the VM, run commands in it and copy files in and out."
    case .template: "Agents can see the VM and clone new VMs from it, which they then fully control."
    }
  }
}

extension AgentAuditEntry.Outcome {
  var title: String {
    switch self {
    case .ok: "OK"
    case .denied: "Denied"
    case .failed: "Failed"
    }
  }

  /// The pill colour. System green is too light for small text on its own tint in light mode,
  /// so OK uses a darker green there.
  func tint(in colorScheme: ColorScheme) -> Color {
    switch self {
    case .ok: colorScheme == .dark ? .green : Color(red: 0.09, green: 0.44, blue: 0.17)
    case .denied: .orange
    case .failed: .red
    }
  }
}

/// Why Tartelette can't use `agents.json`: a short explanation for the user, and the technical
/// details for whoever fixes the file.
struct AgentSettingsProblem: Equatable {
  let summary: String
  let details: String

  /// - Parameters:
  ///   - error: What loading the file threw.
  ///   - contents: The file as it is now, when it can be read. Valid JSON that still fails to load
  ///     means a value is wrong rather than the syntax.
  init(_ error: any Error, contents: Data?) {
    switch error {
    case AgentStoreError.malformed(let file, let detail):
      let isJSON = contents.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } != nil
      summary = isJSON ? "\(file) has a value Tartelette doesn't understand." : "\(file) isn't valid JSON."
      details = detail
    case AgentStoreError.unreadable(let file, let detail):
      summary = "Tartelette can't read \(file)."
      details = detail
    default:
      summary = "Tartelette can't read its agent settings."
      details = error.localizedDescription
    }
  }
}

/// How the sidebar marks a VM agents can reach.
enum AgentIndicator: Equatable {
  /// The user shared the VM with agents at this level.
  case shared(AgentAccess)
  /// An agent created the VM and fully controls it.
  case createdByAgent(client: String?)

  /// Nil while agents are off, or for a VM that is neither shared nor created by an agent.
  init?(enabled: Bool, creator: AgentVMEntry?, access: AgentAccess) {
    guard enabled else { return nil }
    if let creator {
      self = .createdByAgent(client: creator.client)
    } else if access != .none {
      self = .shared(access)
    } else {
      return nil
    }
  }

  var help: String {
    switch self {
    case .shared(let access): "Shared with AI agents: \(access.title)"
    case .createdByAgent(let client): "Created by \(client ?? "an agent"), which fully controls it"
    }
  }

  /// Grey for shared VMs; the "Full control" purple for VMs an agent created.
  var tint: Color {
    switch self {
    case .shared: .secondary
    case .createdByAgent: .purple
    }
  }
}
