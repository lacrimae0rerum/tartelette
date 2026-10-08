import AppKit
import SwiftUI
import TarteletteKit

/// `tart export <name> <path>`: writes the VM to a compressed `.tvm` archive.
///
/// A destination is always passed — without one Tart asks a yes/no question on stdin.
struct ExportSheet: View {
  let vmName: String

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var destination: URL?

  var body: some View {
    SheetScaffold(
      title: "Export “\(displayName)”",
      subtitle: "Save a compressed archive you can import on any Mac with Tart.",
      systemImage: "square.and.arrow.up",
      commandLine: TartCommand.export(name: vmName, path: destination?.path ?? "<file.tvm>").previewLine,
      primaryTitle: "Export",
      isPrimaryDisabled: destination == nil,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("Save to") {
          PathPickerField(path: destination?.path, placeholder: "Choose a location", buttonTitle: "Choose…") {
            choose()
          }
          if let destination, FileManager.default.fileExists(atPath: destination.path) {
            ValidationText(message: "“\(destination.lastPathComponent)” already exists and will be replaced.")
          }
        }
        SheetFormRow("Format") {
          Text("Tart archive (.tvm) — Apple Archive, LZFSE-compressed")
          if let size = sizeDescription {
            FieldHint(size)
          }
        }
      }
      if model.library.isRunning(vmName) {
        SheetNote(.warning, "“\(vmName)” is running. Its disk may change while it's being archived — shut it down first for a consistent export.")
      } else if model.library.state(of: vmName) == .suspended {
        SheetNote(.info, "Suspended state isn't exported; the imported VM starts fresh.")
      }
    }
    .frame(width: 560, height: model.library.isRunning(vmName) ? 380 : 320)
    .onAppear {
      if destination == nil {
        destination = URL.desktopDirectory.appendingPathComponent("\(fileBaseName).tvm")
      }
    }
  }

  private var displayName: String {
    model.library.vm(named: vmName) == nil ? ReferenceValidation.suggestedLocalName(for: vmName) : vmName
  }

  private var fileBaseName: String { ReferenceValidation.suggestedLocalName(for: displayName) }

  private var sizeDescription: String? {
    guard let bytes = model.metrics.vmAllocatedBytes[vmName], bytes > 0 else { return nil }
    return "The VM uses \(Formatting.bytes(bytes)) on disk; the archive is usually smaller."
  }

  private func choose() {
    if let url = FilePanels.saveFile(
      title: "Export “\(displayName)”", suggestedName: "\(fileBaseName).tvm", contentTypes: [.tartArchive],
      directoryURL: destination?.deletingLastPathComponent() ?? URL.desktopDirectory)
    {
      destination = url
    }
  }

  private func submit() {
    guard let destination else { return }
    let file = destination
    model.library.performInBackground(.export(name: vmName, path: file.path), title: "Export \(displayName)") {
      NSWorkspace.shared.activateFileViewerSelecting([file])
    }
    model.navigation.selection = .activity
    dismiss()
  }
}
