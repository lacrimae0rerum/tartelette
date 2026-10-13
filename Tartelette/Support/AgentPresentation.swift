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

  var tint: Color {
    switch self {
    case .ok: .green
    case .denied: .orange
    case .failed: .red
    }
  }
}
