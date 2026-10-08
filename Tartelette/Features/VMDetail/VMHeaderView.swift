import SwiftUI
import TarteletteKit

/// The top of the VM detail screen: identity, state and the controls used most often.
struct VMHeaderView: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    let running = vm.state.isRunning
    let os = library.os(of: vm.name)

    HStack(alignment: .center, spacing: 14) {
      OSIcon(os: os, size: 52)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Text(vm.name)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
          StateBadge(state: vm.state)
        }
        Text(specification(os: os))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let origin = originNote {
          Text(origin)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .layoutPriority(1)

      Spacer(minLength: 12)

      HStack(spacing: 8) {
        if let url = library.vncURLs[vm.name] {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Label("Screen Sharing", systemImage: "rectangle.on.rectangle")
          }
          .help("Open the VM's VNC session in Screen Sharing")
        }
        if running {
          AccessButtons(name: vm.name)
          LiveClipboardToggle(name: vm.name)
        }
        LifecycleButton(vm: vm)
      }
      .labelStyle(.iconOnly)
      .controlSize(.large)
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 10)
  }

  private func specification(os: VMOperatingSystem) -> String {
    var parts = [os.displayName]
    if let config = model.library.config(of: vm.name) {
      parts.append("\(config.cpuCount) CPU")
      parts.append(Formatting.memory(config.memorySize))
    }
    if let disk = vm.diskGB { parts.append("\(Formatting.gigabytes(disk)) disk") }
    return parts.joined(separator: " · ")
  }

  private var originNote: String? {
    guard vm.state.isRunning else {
      if vm.state == .suspended { return "Suspended — starting resumes where it left off" }
      return nil
    }
    if !model.library.wasStartedByTartelette(vm.name) {
      return "Started outside Tartelette"
    }
    if let options = model.library.launchedOptions[vm.name], options.display == .headless {
      return "Running without a window"
    }
    return nil
  }
}

/// Show Window, Terminal and SSH for a running VM.
private struct AccessButtons: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    ControlGroup {
      Button {
        library.showWindow(name)
      } label: {
        Label("Show Window", systemImage: "macwindow")
      }
      .help("Bring the VM's window to the front")

      Button {
        library.openTerminal(name)
      } label: {
        Label("Terminal", systemImage: "terminal")
      }
      .help("Open an interactive shell in Terminal (needs the Tart Guest Agent)")

      Button {
        Task { await library.openSSH(name) }
      } label: {
        Label("SSH", systemImage: "network")
      }
      .help("Open an SSH session in Terminal as “\(model.settings.sshUsername)”")
    }
    .fixedSize()
  }
}

/// Toggles live clipboard sync for VMs that use the Tartelette bridge.
private struct LiveClipboardToggle: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let clipboard = model.clipboard
    if clipboard.engine(for: name) == .bridge {
      let state = clipboard.state(for: name)
      Toggle(
        isOn: Binding(
          get: { state.liveSyncEnabled },
          set: { clipboard.setLiveSync($0, for: name) })
      ) {
        Label(
          state.isSyncing ? "Live Clipboard On" : "Live Clipboard",
          systemImage: state.isSyncing ? "doc.on.clipboard.fill" : "doc.on.clipboard")
      }
      .toggleStyle(.button)
      .help(helpText(state))
    }
  }

  private func helpText(_ state: VMClipboardState) -> String {
    if state.isSyncing { return "Copy and paste flow between your Mac and the VM. Click to pause." }
    if state.liveSyncEnabled { return "Live clipboard waits for the Tart Guest Agent: \(state.agentStatus.detail)" }
    return "Turn on live copy and paste between your Mac and the VM"
  }
}

/// Start (stopped/suspended) or Shut Down (running), each with every variant in its menu.
private struct LifecycleButton: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    if vm.state.isRunning {
      Menu {
        StopMenuItems(name: vm.name)
      } label: {
        Label("Shut Down", systemImage: "power")
          .labelStyle(.titleAndIcon)
      } primaryAction: {
        library.requestShutdown(vm.name)
      }
      .menuStyle(.button)
      .buttonStyle(.bordered)
      .fixedSize()
      .help("Ask the guest to shut down. Use the menu to power off, suspend or force stop.")
    } else {
      Menu {
        StartMenuItems(name: vm.name)
      } label: {
        Label(vm.state == .suspended ? "Resume" : "Start", systemImage: "play.fill")
          .labelStyle(.titleAndIcon)
      } primaryAction: {
        library.start(vm.name)
      }
      .menuStyle(.button)
      .buttonStyle(.borderedProminent)
      .fixedSize()
      .help("Start with the saved run options. Use the menu for other ways to start.")
    }
  }
}
