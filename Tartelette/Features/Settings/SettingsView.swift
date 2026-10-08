import AppKit
import SwiftUI
import TarteletteKit

/// The Settings window.
struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
      ClipboardSettings()
        .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
      MonitoringSettings()
        .tabItem { Label("Monitoring", systemImage: "chart.xyaxis.line") }
      NetworkSettings()
        .tabItem { Label("Registries & Network", systemImage: "network") }
    }
    .frame(width: 560)
    .scenePadding()
  }
}

// MARK: - General

private struct GeneralSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings

    Form {
      Section("Tart") {
        LabeledContent("Executable") {
          HStack {
            Text(model.context.environment?.executable.path ?? "Not found")
              .foregroundStyle(model.context.isAvailable ? .primary : Color.red)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Spacer()
            Button("Choose…", action: chooseExecutable)
            if settings.tartExecutablePath != nil {
              Button("Automatic") {
                settings.tartExecutablePath = nil
                model.reloadEnvironment()
              }
            }
          }
        }
        LabeledContent("Version", value: model.context.version ?? "—")
        LabeledContent("Home (TART_HOME)") {
          HStack {
            Text(model.context.paths.home.path(percentEncoded: false))
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Spacer()
            Button("Choose…", action: chooseHome)
            if settings.tartHome != nil {
              Button("Default") {
                settings.tartHome = nil
                model.reloadEnvironment()
              }
            }
          }
        }
      }

      Section("App") {
        Toggle("Show in menu bar", isOn: $settings.showMenuBarExtra)
        Toggle(
          "Open at login",
          isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
        if let error = settings.launchAtLoginError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        Toggle("Shut down VMs started by Tartelette when quitting", isOn: $settings.stopVMsOnQuit)
        Toggle("Notify when long operations finish", isOn: $settings.notifyOnCompletion)
        Picker("Refresh VM list every", selection: $settings.refreshInterval) {
          Text("2 seconds").tag(2.0)
          Text("3 seconds").tag(3.0)
          Text("5 seconds").tag(5.0)
          Text("10 seconds").tag(10.0)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func chooseExecutable() {
    let panel = NSOpenPanel()
    panel.title = "Choose the tart Executable"
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.settings.tartExecutablePath = url.path
    model.reloadEnvironment()
  }

  private func chooseHome() {
    let panel = NSOpenPanel()
    panel.title = "Choose Tart's Home Folder"
    panel.message = "Tart keeps VMs and caches here (TART_HOME)."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.settings.tartHome = url.path
    model.reloadEnvironment()
  }
}

// MARK: - Clipboard

private struct ClipboardSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings

    Form {
      Section {
        Picker("Default engine", selection: $settings.defaultClipboardEngine) {
          ForEach(ClipboardEngine.allCases) { engine in
            Text(engine.title).tag(engine)
          }
        }
        Text(settings.defaultClipboardEngine.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Turn on live sync when a VM starts", isOn: $settings.liveSyncByDefault)
        Toggle("Sync copied files and folders", isOn: $settings.syncFiles)
        Stepper(value: $settings.maxAutoTransferMB, in: 1...2048, step: settings.maxAutoTransferMB < 50 ? 5 : 50) {
          LabeledContent("Automatic sync limit", value: "\(settings.maxAutoTransferMB) MB")
        }
      } header: {
        Text("Copy and paste")
      } footer: {
        Text("The Tartelette bridge copies text, rich text, images and files through the Tart Guest Agent and verifies every transfer. Larger items can still be sent manually.")
      }

      Section {
        TextField("User name", text: $settings.sshUsername)
        SecureField("Password", text: $settings.sshPassword, prompt: Text("admin"))
      } header: {
        Text("SSH fallback")
      } footer: {
        Text("Used for guests without the Tart Guest Agent (Remote Login must be enabled in the guest). The password is stored in your Keychain.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Monitoring

private struct MonitoringSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings

    Form {
      Section {
        Picker("Sample every", selection: $settings.metricsInterval) {
          Text("1 second").tag(1.0)
          Text("2 seconds").tag(2.0)
          Text("5 seconds").tag(5.0)
        }
        Picker("Keep history for", selection: $settings.historyMinutes) {
          Text("5 minutes").tag(5)
          Text("15 minutes").tag(15)
          Text("30 minutes").tag(30)
          Text("60 minutes").tag(60)
        }
        Toggle("Collect metrics from inside guests", isOn: $settings.guestMetricsEnabled)
      } footer: {
        Text("Host-side numbers come from the Virtualization processes of each VM. Guest metrics need the Tart Guest Agent.")
      }
    }
    .formStyle(.grouped)
    .onChange(of: settings.metricsInterval) { model.metrics.settingsChanged() }
    .onChange(of: settings.historyMinutes) { model.metrics.settingsChanged() }
  }
}

// MARK: - Registries & network

private struct NetworkSettings: View {
  @Environment(AppModel.self) private var model
  @State private var softnet: URL?
  @State private var softnetPrivileged = false
  @State private var softnetError: String?

  var body: some View {
    @Bindable var settings = model.settings

    Form {
      Section {
        Toggle("Never prune caches automatically", isOn: $settings.disableAutoPrune)
      } header: {
        Text("Storage")
      } footer: {
        Text("Sets TART_NO_AUTO_PRUNE. By default Tart frees cache space automatically before pulls and clones.")
      }

      Section {
        TextField("User name", text: $settings.registryUsername, prompt: Text("TART_REGISTRY_USERNAME"))
        SecureField("Password", text: $settings.registryPassword, prompt: Text("TART_REGISTRY_PASSWORD"))
        TextField("Only for host", text: $settings.registryHostname, prompt: Text("Any registry"))
      } header: {
        Text("Registry credentials override")
      } footer: {
        Text("Passed to Tart as TART_REGISTRY_* variables, which take precedence over Docker and Keychain credentials. Prefer Registries › Log In for everyday use.")
      }

      Section {
        LabeledContent("Softnet") {
          if let softnet {
            HStack {
              Text(softnet.path).lineLimit(1).truncationMode(.middle)
              Pill(
                title: softnetPrivileged ? "Ready" : "Needs setup",
                systemImage: softnetPrivileged ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: softnetPrivileged ? .green : .orange)
            }
          } else {
            Text("Not installed").foregroundStyle(.secondary)
          }
        }
        if let softnet, !softnetPrivileged {
          Button("Allow Softnet to Run…") { enable(softnet) }
        }
        if let softnetError {
          Text(softnetError).font(.caption).foregroundStyle(.red)
        }
      } header: {
        Text("Software networking")
      } footer: {
        Text("Softnet isolates VM traffic (--net-softnet). It must be owned by root with the setuid bit; Tart only offers to set this up when run in a terminal, so Tartelette asks for your administrator password instead.")
      }
    }
    .formStyle(.grouped)
    .onChange(of: settings.disableAutoPrune) { model.reloadEnvironment() }
    .onChange(of: settings.registryUsername) { model.reloadEnvironment() }
    .onChange(of: settings.registryPassword) { model.reloadEnvironment() }
    .onChange(of: settings.registryHostname) { model.reloadEnvironment() }
    .task { inspectSoftnet() }
  }

  private func inspectSoftnet() {
    guard let environment = model.context.environment else { return }
    softnet = SoftnetSupport.locate(environment: environment)
    softnetPrivileged = softnet.map(SoftnetSupport.isPrivileged) ?? false
  }

  private func enable(_ url: URL) {
    Task {
      do {
        try await SoftnetSupport.enablePrivileges(for: url, runner: model.context.runner)
        softnetError = nil
      } catch ProcessRunError.cancelled {
        softnetError = nil
      } catch {
        softnetError = error.localizedDescription
      }
      inspectSoftnet()
    }
  }
}
