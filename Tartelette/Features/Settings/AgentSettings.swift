import AppKit
import SwiftUI
import TarteletteKit

/// Settings › Agents: the master switch, how to connect an agent, what agents can reach and what
/// they did recently.
struct AgentSettings: View {
  @Environment(AppModel.self) private var model
  @State private var confirmingReset = false

  private let setup = AgentSetup.bundled

  var body: some View {
    let agents = model.agents

    Form {
      if let loadError = agents.loadError {
        Section {
          InlineNotice(
            .error,
            "Tartelette can't read its agent settings, so agents can't use any VM. Fix agents.json or reset it.")
          Text(loadError)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([agents.paths.policyFile]) }
            Spacer()
            Button("Reset Agent Settings…", role: .destructive) { confirmingReset = true }
          }
        }
      }

      Section {
        Toggle(
          "Let AI agents use Tartelette's VMs",
          isOn: Binding(get: { agents.enabled }, set: { agents.setEnabled($0) }))
          .disabled(agents.loadError != nil)
        if let saveError = agents.saveError {
          Text(saveError).font(.caption).foregroundStyle(.red)
        }
      } footer: {
        Text("Agents such as Claude Code, Codex or Cursor connect through Tartelette's MCP helper. They only see the VMs you share one by one, in each VM's Configuration tab, and every call they make is logged below.")
      }

      Section {
        if let setup {
          LabeledContent("Helper") {
            Text(setup.helperPath)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code")
            CommandPreview(commandLine: setup.claudeCommand)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Other MCP clients")
            CommandPreview(commandLine: setup.mcpConfiguration, systemImage: "curlybraces")
          }
        } else {
          InlineNotice(
            .warning,
            "This copy of Tartelette doesn't include the tartelette-mcp helper, so agents can't connect to it. Install a release build to use agents.")
        }
      } header: {
        Text("Setup")
      } footer: {
        Text("Run the command in Terminal, or add the JSON to your client's MCP settings. If you move Tartelette, set it up again.")
      }

      SharedVMsSection()
      ActivitySection()
    }
    .formStyle(.grouped)
    .frame(height: 600)
    .onAppear { agents.reload() }
    .task {
      // Refreshes the activity while the pane is visible; the task ends when it disappears.
      while !Task.isCancelled {
        agents.refreshActivity(limit: 50)
        try? await Task.sleep(for: .seconds(2))
      }
    }
    .confirmationDialog("Reset agent settings?", isPresented: $confirmingReset) {
      Button("Reset", role: .destructive) { agents.resetToDefaults() }
    } message: {
      Text("agents.json is replaced with the defaults: agents are turned off and no VM is shared.")
    }
  }
}

// MARK: - What agents can reach

private struct SharedVMsSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let agents = model.agents
    let shared = agents.sharedVMs
    let created = agents.agentCreatedVMs

    Section {
      if shared.isEmpty && created.isEmpty {
        Text("No VM is shared with agents yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(shared) { vm in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(vm.name)
            if model.library.hasLoaded, model.library.vm(named: vm.name) == nil {
              Text("Not found in Tart").font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Picker(
            "Access",
            selection: Binding(get: { agents.access(for: vm.name) }, set: { agents.setAccess($0, for: vm.name) })
          ) {
            ForEach(AgentAccess.allCases, id: \.self) { level in
              Text(level.title).tag(level)
            }
          }
          .labelsHidden()
          .fixedSize()
          .disabled(agents.loadError != nil)
          ShowVMButton(name: vm.name)
        }
      }
      ForEach(created, id: \.name) { entry in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
            Text("Created by \(entry.client ?? "an agent") from \(entry.source), \(Formatting.relative(entry.createdAt).lowercased())")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Pill(title: "Full control", systemImage: "sparkles", tint: .purple)
          ShowVMButton(name: entry.name)
        }
      }
    } header: {
      Text("VMs agents can use")
    } footer: {
      Text("Share a VM from its Configuration tab. Agents fully control the VMs they create, including deleting them.")
    }
  }
}

private struct ShowVMButton: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    Button {
      model.navigation.show(name, tab: .configuration)
    } label: {
      Image(systemName: "arrow.right.circle")
    }
    .buttonStyle(.borderless)
    .help("Show “\(name)” in Tartelette")
    .accessibilityLabel("Show \(name)")
  }
}

// MARK: - Activity

private struct ActivitySection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let agents = model.agents

    Section {
      if agents.recentActivity.isEmpty {
        Text("No agent activity yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(agents.recentActivity.enumerated()), id: \.offset) { _, entry in
        ActivityRow(entry: entry)
      }
    } header: {
      HStack {
        Text("Recent activity")
        Spacer()
        Button("Show Log in Finder", action: revealLog)
          .controlSize(.small)
      }
    }
  }

  private func revealLog() {
    let paths = model.agents.paths
    if FileManager.default.fileExists(atPath: paths.auditLogFile.path) {
      NSWorkspace.shared.activateFileViewerSelecting([paths.auditLogFile])
    } else {
      try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
      NSWorkspace.shared.open(paths.logs)
    }
  }
}

private struct ActivityRow: View {
  let entry: AgentAuditEntry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(entry.tool).font(.callout.monospaced())
          if let vm = entry.vm {
            Text("· \(vm)").foregroundStyle(.secondary)
          }
        }
        if let detail = entry.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
        }
        Text("\(entry.date.formatted(date: .abbreviated, time: .standard)) · \(entry.client ?? "Unknown client")")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Pill(title: entry.outcome.title, tint: entry.outcome.tint)
    }
    .accessibilityElement(children: .combine)
  }
}
