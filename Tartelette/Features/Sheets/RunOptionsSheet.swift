import SwiftUI
import TarteletteKit

/// “Start with Options…”: edit every `tart run` option for one launch, optionally remembering it.
struct RunOptionsSheet: View {
  let vmName: String
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft: RunProfile?
  @State private var remember = false
  @State private var softnet: SoftnetState = .unknown

  var body: some View {
    let os = model.library.os(of: vmName)

    VStack(spacing: 0) {
      HStack(spacing: 12) {
        OSIcon(os: os, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text("Start “\(vmName)”").font(.title3.weight(.semibold))
          Text("Choose how to run the VM this time.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 8)

      if let draft = Binding($draft) {
        RunOptionsEditor(profile: draft, vmName: vmName, os: os)
        footer(draft.wrappedValue, os: os)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 720)
    .onAppear {
      draft = model.profiles.profile(for: vmName)
      softnet = SoftnetState.inspect(model.context)
    }
  }

  private func footer(_ draft: RunProfile, os: VMOperatingSystem) -> some View {
    let issues = RunOptionsValidation.issues(for: draft, os: os, softnet: softnet)
    let hasErrors = issues.contains { $0.severity == .error }
    let running = model.library.isRunning(vmName)
    let command = TartCommand.run(draft.effectiveOptions(for: os))

    return VStack(spacing: 10) {
      if !issues.isEmpty {
        RunOptionsIssueList(issues: issues)
      }
      CommandPreview(commandLine: command.commandLine)
      HStack {
        Toggle("Remember these options for “\(vmName)”", isOn: $remember)
          .toggleStyle(.checkbox)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(running ? "Save" : "Start") {
          if remember || running { model.profiles.save(draft, for: vmName) }
          if !running {
            model.library.start(vmName, options: draft.options, clipboardEngine: draft.clipboardEngine)
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(hasErrors && !running)
      }
      if running {
        Text("“\(vmName)” is already running. Saved options apply the next time it starts.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(20)
    .background(.bar)
  }
}
