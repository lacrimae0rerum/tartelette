import SwiftUI
import TarteletteKit

/// A sidebar row: OS glyph, name, live summary and state. Accepts dropped files (copied to the VM).
struct VMRow: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model
  @State private var isDropTarget = false

  var body: some View {
    HStack(spacing: 10) {
      OSIcon(os: model.library.os(of: vm.name), size: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(vm.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .monospacedDigit()
      }
      Spacer(minLength: 4)
      if model.clipboard.state(for: vm.name).isSyncing {
        Image(systemName: "arrow.left.arrow.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .help("Live clipboard sync is on")
      }
      if let agentNote {
        Image(systemName: "sparkles")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .help(agentNote)
          .accessibilityLabel(agentNote)
      }
      StatusDot(state: vm.state)
    }
    .padding(.vertical, 2)
    .overlay {
      if isDropTarget {
        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard vm.state.isRunning, !files.isEmpty else { return false }
      Task { await model.clipboard.sendFiles(files, to: vm.name) }
      return true
    } isTargeted: { targeted in
      isDropTarget = targeted && vm.state.isRunning
    }
    .help(vm.state.isRunning ? "Drop files here to copy them to the VM's Desktop" : vm.state.title)
  }

  /// Set while agents can reach this VM: shared with them, or created by one.
  private var agentNote: String? {
    let agents = model.agents
    guard agents.enabled else { return nil }
    if let creator = agents.creator(of: vm.name) {
      return "Created by \(creator.client ?? "an agent"), which fully controls it"
    }
    let access = agents.access(for: vm.name)
    return access == .none ? nil : "Shared with AI agents: \(access.title)"
  }

  private var subtitle: String {
    if vm.state.isRunning, let sample = model.metrics.latest(for: vm.name) {
      return "CPU \(Formatting.cpu(sample.cpuPercent)) · \(Formatting.memory(sample.memoryBytes))"
    }
    guard let config = model.library.config(of: vm.name) else { return vm.state.title }
    let memory = Formatting.memory(config.memorySize)
    return "\(vm.state.title) · \(config.cpuCount) CPU · \(memory)"
  }
}
