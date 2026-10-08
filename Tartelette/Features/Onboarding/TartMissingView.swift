import AppKit
import SwiftUI
import TarteletteKit
import UniformTypeIdentifiers

/// Shown when no `tart` executable could be found.
struct TartMissingView: View {
  @Environment(AppModel.self) private var model
  @State private var checked = false

  var body: some View {
    VStack(spacing: 18) {
      Image("BrandMark")
        .resizable()
        .frame(width: 112, height: 112)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
      VStack(spacing: 6) {
        Text("Tart Isn't Installed")
          .font(.largeTitle.weight(.semibold))
        Text("Tartelette manages virtual machines with Tart, the virtualization tool for Apple silicon. Install it with Homebrew, then check again.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .frame(maxWidth: 460)
      }
      CommandPreview(commandLine: Links.installCommand) {
        do {
          try TerminalLauncher.open(commandLine: Links.installCommand, title: "Install Tart")
        } catch {
          model.navigation.show(error: error, title: "Couldn't open Terminal")
        }
      }
      .frame(maxWidth: 420)
      HStack(spacing: 12) {
        Button("Locate tart…", action: locate)
        Button("Check Again") {
          model.reloadEnvironment()
          checked = true
        }
        .buttonStyle(.borderedProminent)
      }
      if checked, !model.context.isAvailable {
        Text("Still not found in /opt/homebrew/bin, /usr/local/bin or your PATH.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Link("Learn more about Tart", destination: Links.tartDocumentation)
        .font(.callout)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
