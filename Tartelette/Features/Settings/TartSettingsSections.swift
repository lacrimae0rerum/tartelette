import SwiftUI
import TarteletteKit

/// Settings › General › Tart, below the executable and home rows: the manual update check and what
/// to do about its result, the running install and its errors.
struct TartUpdateRows: View {
  @Environment(AppModel.self) private var model
  let presentation: TartSettingsPresentation

  var body: some View {
    let installation = model.installation

    LabeledContent {
      HStack {
        if presentation.isChecking {
          ProgressView().controlSize(.small)
        }
        Button("Check for Updates") { installation.checkForUpdates() }
        // Homebrew's Tart updates in Terminal; the managed copy is the secondary choice below.
        if let title = presentation.installTitle, presentation.upgradeCommand == nil {
          Button(title) { installation.installLatest() }
            .buttonStyle(.borderedProminent)
        }
      }
      .disabled(installation.isBusy)
    } label: {
      Text("Updates")
      if let status = presentation.status {
        Text(status)
          .foregroundStyle(presentation.statusIsProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      }
    }

    if let command = presentation.upgradeCommand {
      VStack(alignment: .leading, spacing: 6) {
        Text("Update Homebrew's Tart in Terminal:")
        CommandPreview(commandLine: command) {
          do {
            try TerminalLauncher.open(commandLine: command, title: "Update Tart")
          } catch {
            model.navigation.show(error: error, title: "Couldn't open Terminal")
          }
        }
      }
      if let title = presentation.installTitle {
        LabeledContent {
          Button(title) { installation.installLatest() }
            .disabled(installation.isBusy)
        } label: {
          Text(presentation.installNote ?? "")
            .foregroundStyle(.secondary)
        }
      }
    }

    if let operation = installation.operation {
      TartInstallProgressView(
        progress: TartOperationProgress(operation, downloaded: installation.downloaded),
        cancel: { installation.cancel() })
    }
    if let error = installation.operationError {
      InlineNotice(.error, error)
    }
  }
}

/// The footer of Settings › General › Tart: the network promise and Tart's license.
struct TartSettingsFooter: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(TartSettingsPresentation.networkNote)
      Link("Tart's License (FSL-1.1-ALv2)", destination: Links.tartLicense)
        // Footers style their text, not their links.
        .font(.subheadline)
    }
  }
}

/// Settings › General › Managed Copy: the versions Tartelette downloaded, going back, removing, and
/// how to use that Tart in Terminal.
struct ManagedTartSection: View {
  @Environment(AppModel.self) private var model
  let presentation: TartSettingsPresentation
  @State private var confirmingRemoval = false

  /// The managed Tart's folder through `current`, so the line keeps working after updates.
  private let directory = ManagedTartLayout.standard.currentExecutable.deletingLastPathComponent()

  var body: some View {
    let installation = model.installation

    Section {
      if let versions = presentation.managedVersions {
        LabeledContent("Installed versions", value: versions)
      }
      HStack {
        if let title = presentation.rollbackTitle {
          Button(title) { installation.rollback() }
        }
        Spacer()
        Button("Remove Managed Copy…", role: .destructive) { confirmingRemoval = true }
      }
      .disabled(installation.isBusy)
      VStack(alignment: .leading, spacing: 6) {
        Text("To use this Tart in your own Terminal, run this line or add it to ~/.zshrc:")
        CommandPreview(commandLine: TartSettingsPresentation.terminalHint(for: directory))
      }
    } header: {
      Text("Managed Copy")
    }
    .confirmationDialog("Remove the managed copy of Tart?", isPresented: $confirmingRemoval) {
      Button("Remove", role: .destructive) { installation.removeManagedCopy() }
    } message: {
      Text("Your VMs and images aren't affected. Tartelette will use another installed Tart, if there is one.")
    }
  }
}
