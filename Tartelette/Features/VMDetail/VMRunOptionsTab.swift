import SwiftUI
import TarteletteKit

extension RunProfile {
  /// The options `tart run` actually receives: the clipboard engine decides `--no-clipboard`
  /// (the bridge and Off both disable Tart's text-only SPICE clipboard).
  func effectiveOptions(for os: VMOperatingSystem) -> RunOptions {
    var options = self.options
    let engine = clipboardEngine.resolved(for: os)
    if engine == .bridge || engine == .off { options.noClipboard = true }
    return options
  }
}

/// The saved run profile of a VM: how Tartelette starts it.
struct VMRunOptionsTab: View {
  let vmName: String
  @Environment(AppModel.self) private var model
  @State private var draft: RunProfile?
  @State private var softnet: SoftnetState = .unknown

  var body: some View {
    let saved = model.profiles.profile(for: vmName)

    Group {
      if let draft = Binding($draft) {
        RunOptionsEditor(profile: draft, vmName: vmName, os: model.library.os(of: vmName))
          .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(draft: draft.wrappedValue, saved: saved)
          }
      } else {
        ProgressView()
      }
    }
    .onAppear {
      draft = saved
      softnet = SoftnetState.inspect(model.context)
    }
    .onChange(of: saved) { oldValue, newValue in
      // Adopt changes saved elsewhere (e.g. the sheet) unless there are unsaved edits here.
      if draft == oldValue { draft = newValue }
    }
  }

  private func footer(draft: RunProfile, saved: RunProfile) -> some View {
    let os = model.library.os(of: vmName)
    let issues = RunOptionsValidation.issues(for: draft, os: os, softnet: softnet)
    let hasErrors = issues.contains { $0.severity == .error }
    let isDirty = draft != saved
    let running = model.library.isRunning(vmName)
    let command = TartCommand.run(draft.effectiveOptions(for: os))

    return VStack(spacing: 10) {
      if !issues.isEmpty {
        RunOptionsIssueList(issues: issues)
      }
      CommandPreview(commandLine: command.commandLine)
      HStack {
        Button("Restore Defaults") {
          model.profiles.reset(vmName)
          self.draft = model.profiles.profile(for: vmName)
        }
        .disabled(!model.profiles.hasCustomProfile(vmName) && draft == model.profiles.profile(for: vmName))
        if running {
          Label("Changes apply the next time the VM starts.", systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Revert") { self.draft = saved }
          .disabled(!isDirty)
        Button("Save") { model.profiles.save(draft, for: vmName) }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!isDirty)
        if !running {
          Button("Save and Start") {
            model.profiles.save(draft, for: vmName)
            model.library.start(vmName, options: draft.options, clipboardEngine: draft.clipboardEngine)
          }
          .buttonStyle(.borderedProminent)
          .disabled(hasErrors)
        }
      }
    }
    .padding(16)
    .background(.bar)
  }
}
