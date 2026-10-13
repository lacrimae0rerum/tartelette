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
      AgentSettings()
        .tabItem { Label("Agents", systemImage: "sparkles") }
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

/// Registry override fields being edited.
///
/// Edits stay local until the user commits them explicitly (Return, Apply, or leaving the pane),
/// and only a consistent set is ever applied: a user name together with a password, or neither.
/// So a half-typed password is never written to the Keychain and Tart never runs with an
/// incomplete `TART_REGISTRY_*` set; the environment is rebuilt once per commit, not per keystroke.
struct RegistryOverrideDraft: Equatable {
  var username = ""
  var password = ""
  var hostname = ""

  init() {}

  init(username: String, password: String, hostname: String) {
    self.username = username
    self.password = password
    self.hostname = hostname
  }

  init(_ settings: AppSettings) {
    self.init(
      username: settings.registryUsername, password: settings.registryPassword, hostname: settings.registryHostname)
  }

  private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var trimmedHostname: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Why the draft can't be applied yet, or nil when it can.
  var problem: String? {
    let hasUser = !trimmedUsername.isEmpty
    let hasPassword = !password.isEmpty
    if hasUser != hasPassword { return "Enter both a user name and a password, or clear both." }
    if !hasUser, !trimmedHostname.isEmpty { return "A host restriction needs a user name and a password." }
    if trimmedHostname.contains("/") {
      return "Enter only the registry host, e.g. ghcr.io (no scheme or path)."
    }
    return nil
  }

  var isConsistent: Bool { problem == nil }

  /// The values to store, trimmed.
  var normalized: RegistryOverrideDraft {
    RegistryOverrideDraft(username: trimmedUsername, password: password, hostname: trimmedHostname)
  }

  /// Whether committing the draft would change the stored overrides.
  func differs(username: String, password: String, hostname: String) -> Bool {
    normalized != RegistryOverrideDraft(username: username, password: password, hostname: hostname)
  }

  func differs(from settings: AppSettings) -> Bool {
    differs(username: settings.registryUsername, password: settings.registryPassword, hostname: settings.registryHostname)
  }
}

private struct NetworkSettings: View {
  @Environment(AppModel.self) private var model
  @State private var softnet: URL?
  @State private var softnetPrivileged = false
  @State private var softnetError: String?
  @State private var registryDraft = RegistryOverrideDraft()
  @State private var registryDraftLoaded = false

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
        TextField("User name", text: $registryDraft.username, prompt: Text("TART_REGISTRY_USERNAME"))
          .onSubmit(applyRegistryDraft)
        SecureField("Password", text: $registryDraft.password, prompt: Text("TART_REGISTRY_PASSWORD"))
          .onSubmit(applyRegistryDraft)
        TextField("Only for host", text: $registryDraft.hostname, prompt: Text("Any registry"))
          .onSubmit(applyRegistryDraft)
        HStack {
          if let problem = registryDraft.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Spacer()
          Button("Revert") { registryDraft = RegistryOverrideDraft(settings) }
            .disabled(!registryDraft.differs(from: settings))
          Button("Apply", action: applyRegistryDraft)
            .disabled(!registryDraft.isConsistent || !registryDraft.differs(from: settings))
        }
      } header: {
        Text("Registry credentials override")
      } footer: {
        Text("Passed to Tart as TART_REGISTRY_* variables, which take precedence over Docker and Keychain credentials. Changes apply when you press Return or Apply. Prefer Registries › Log In for everyday use.")
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
    .onAppear {
      registryDraft = RegistryOverrideDraft(settings)
      registryDraftLoaded = true
    }
    .onDisappear(perform: applyRegistryDraft)
    .task { inspectSoftnet() }
  }

  /// Commits the edited registry overrides — only a consistent set, and only if it changed — then
  /// rebuilds Tart's environment once. Inconsistent drafts stay unapplied (the form explains why).
  private func applyRegistryDraft() {
    let settings = model.settings
    guard registryDraftLoaded, registryDraft.isConsistent, registryDraft.differs(from: settings) else { return }
    let draft = registryDraft.normalized
    if settings.registryUsername != draft.username { settings.registryUsername = draft.username }
    // Only touch the Keychain when the password actually changed.
    if settings.registryPassword != draft.password { settings.registryPassword = draft.password }
    if settings.registryHostname != draft.hostname { settings.registryHostname = draft.hostname }
    registryDraft = draft
    model.reloadEnvironment()
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
