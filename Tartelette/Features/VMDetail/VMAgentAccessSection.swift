import SwiftUI
import TarteletteKit

/// What AI agents may do with a VM (Configuration tab). Changes are saved at once, apart from the
/// hardware edits around it, since the helper reads them on every agent request.
struct VMAgentAccessSection: View {
  let vmName: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let agents = model.agents
    let creator = agents.creator(of: vmName)
    let current = agents.access(for: vmName)

    Section {
      if let creator {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Created by \(creator.client ?? "an agent")")
            Text("Cloned from “\(creator.source)” \(Formatting.relative(creator.createdAt).lowercased()). Agents fully control this VM: they can start and stop it, run commands in it, copy files and delete it.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "sparkles").foregroundStyle(.purple)
        }
      } else {
        ForEach(AgentAccess.allCases, id: \.self) { level in
          AccessOption(level: level, isSelected: current == level) { agents.setAccess(level, for: vmName) }
        }
        .disabled(agents.loadError != nil)
      }

      if agents.loadError != nil {
        InlineNotice(
          .error, "Tartelette can't read its agent settings. Fix or reset them in Settings › Agents.",
          actionTitle: "Open Settings", action: model.navigation.openSettings)
      } else if !agents.enabled, creator != nil || current != .none {
        InlineNotice(
          .info, "Agents are turned off, so they can't use this VM until you turn them on in Settings › Agents.",
          actionTitle: "Open Settings", action: model.navigation.openSettings)
      }
      if let saveError = agents.saveError {
        InlineNotice(.error, saveError)
      }
    } header: {
      Text("Agent Access")
    } footer: {
      // A VM an agent created has nothing to change here.
      if creator == nil {
        Text("Saved at once: AI agents connected to Tartelette see the change on their next request.")
      }
    }
  }
}

/// One access level as a radio-style row with its explanation.
private struct AccessOption: View {
  let level: AgentAccess
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(level.title)
          Text(level.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
