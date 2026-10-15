import AppKit
import SwiftUI
import TarteletteKit
import UniformTypeIdentifiers

/// Shown when no `tart` executable could be found: installs the official Tart with one click, or
/// explains how to install it in Terminal. A successful install brings up the main window by itself.
struct TartMissingView: View {
  @Environment(AppModel.self) private var model
  @State private var checked = false

  var body: some View {
    // Centered when it fits, scrollable in a short window.
    ViewThatFits(in: .vertical) {
      content
      ScrollView { content }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var content: some View {
    let installation = model.installation
    let alternative = TartOnboardingPresentation.alternative(canUseHomebrew: Links.canInstallTartWithHomebrew)

    return VStack(spacing: 18) {
      Image("BrandMark")
        .resizable()
        .frame(width: 112, height: 112)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
      VStack(spacing: 6) {
        Text("Tart Isn't Installed")
          .font(.largeTitle.weight(.semibold))
        Text("Tartelette manages virtual machines with Tart, the virtualization tool for Apple silicon.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .frame(maxWidth: 460)
      }

      VStack(spacing: 10) {
        if let operation = installation.operation {
          TartInstallProgressView(
            progress: TartOperationProgress(operation, downloaded: installation.downloaded),
            cancel: { installation.cancel() })
        } else {
          Button("Install Tart") { installation.installLatest() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(installation.isBusy)
          Text(TartOnboardingPresentation.installSummary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let error = installation.operationError {
          InlineNotice(.error, error)
        }
      }
      .frame(maxWidth: 420)

      VStack(spacing: 8) {
        Text(alternative.title)
          .font(.headline)
        Text(alternative.message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        CommandPreview(commandLine: alternative.command) {
          do {
            try TerminalLauncher.open(commandLine: alternative.command, title: "Install Tart")
          } catch {
            model.navigation.show(error: error, title: "Couldn't open Terminal")
          }
        }
      }
      .frame(maxWidth: 420)
      .padding(.top, 8)

      HStack(spacing: 12) {
        Button("Locate tart…", action: locate)
        Button("Check Again") {
          model.reloadEnvironment()
          checked = true
        }
      }
      if checked, !model.context.isAvailable {
        Text("Still not found in /opt/homebrew/bin, /usr/local/bin, /Applications/tart.app or your PATH.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 16) {
        Link("Learn more about Tart", destination: Links.tartDocumentation)
        Link("Tart's License (FSL-1.1-ALv2)", destination: Links.tartLicense)
      }
      .font(.callout)
    }
    .padding(40)
    .frame(maxWidth: .infinity)
  }

  private func locate() {
    let panel = NSOpenPanel()
    panel.title = "Locate the tart Executable"
    panel.message = "Choose the tart command-line tool (for example /opt/homebrew/bin/tart)."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.settings.tartExecutablePath = url.path
    model.reloadEnvironment()
    checked = true
  }
}
