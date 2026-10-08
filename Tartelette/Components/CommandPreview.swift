import AppKit
import SwiftUI

/// Shows the exact `tart …` command an action runs, selectable and copyable.
///
/// Every sheet that runs Tart shows one, so the GUI doubles as a way to learn the CLI.
struct CommandPreview: View {
  let commandLine: String
  /// When set, shows a “Run in Terminal” button.
  var runInTerminal: (() -> Void)?

  @State private var copied = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "terminal")
        .foregroundStyle(.secondary)
        .padding(.top, 1)
      Text(commandLine)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      if let runInTerminal {
        Button(action: runInTerminal) {
          Image(systemName: "apple.terminal")
        }
        .buttonStyle(.borderless)
        .help("Run in Terminal")
        .accessibilityLabel("Run in Terminal")
      }
      Button(action: copy) {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.borderless)
      .help("Copy command")
      .accessibilityLabel("Copy command")
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(commandLine, forType: .string)
    withAnimation { copied = true }
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      withAnimation { copied = false }
    }
  }
}
