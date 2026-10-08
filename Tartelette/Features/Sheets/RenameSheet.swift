import SwiftUI
import TarteletteKit

/// `tart rename <name> <new-name>`. The run profile and selection follow the VM.
struct RenameSheet: View {
  let vmName: String

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var newName = ""
  @State private var isWorking = false
  @State private var errorMessage: String?
  @FocusState private var nameFocused: Bool

  var body: some View {
    SheetScaffold(
      title: "Rename “\(vmName)”",
      subtitle: "Run options, history and settings move to the new name.",
      systemImage: "pencil",
      commandLine: TartCommand.rename(name: vmName, newName: previewValue(newName, "new-name")).previewLine,
      primaryTitle: "Rename",
      isPrimaryDisabled: problem != nil,
      isWorking: isWorking,
      errorMessage: errorMessage,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("New name") {
          TextField("VM name", text: $newName)
            .textFieldStyle(.roundedBorder)
            .focused($nameFocused)
          if newName != vmName { ValidationText(message: problem) }
        }
      }
      if model.library.isRunning(vmName) {
        SheetNote(.warning, "Stop “\(vmName)” before renaming it — Tart's window and lock still use the old name.")
      }
    }
    .frame(width: 520, height: model.library.isRunning(vmName) ? 320 : 260)
    .onAppear {
      if newName.isEmpty { newName = vmName }
      nameFocused = true
    }
  }

  private var problem: String? {
    if model.library.isRunning(vmName) { return "Stop the VM first." }
    if newName == vmName { return "Enter a new name." }
    return model.library.problemWithNewName(newName)
  }

  private func submit() {
    guard problem == nil else { return }
    isWorking = true
    errorMessage = nil
    let target = newName
    Task {
      defer { isWorking = false }
      do {
        try await model.library.rename(vmName, to: target)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
