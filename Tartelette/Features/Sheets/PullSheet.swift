import SwiftUI
import TarteletteKit

/// `tart pull <reference>`: downloads an image into the local cache without creating a VM.
struct PullSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var reference = ""
  @State private var insecure = false
  @State private var concurrency = CloneOptions.defaultConcurrency
  @State private var deduplicate = false
  @FocusState private var referenceFocused: Bool

  var body: some View {
    SheetScaffold(
      title: "Pull Image",
      subtitle: "Download an image to the cache. Create VMs from it later in seconds.",
      systemImage: "icloud.and.arrow.down",
      commandLine: command.previewLine,
      primaryTitle: "Pull",
      isPrimaryDisabled: problem != nil,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("Image") {
          HStack(spacing: 8) {
            TextField("ghcr.io/cirruslabs/macos-tahoe-base:latest", text: $reference)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .focused($referenceFocused)
            Menu("Cirrus Labs") {
              Section("macOS") {
                ForEach(ImageCatalog.images.filter { $0.operatingSystem == .macOS }) { image in
                  Button(image.displayName) { reference = image.reference }
                }
              }
              Section("Linux") {
                ForEach(ImageCatalog.images.filter { $0.operatingSystem == .linux }) { image in
                  Button(image.displayName) { reference = image.reference }
                }
              }
            }
            .fixedSize()
          }
          if !reference.isEmpty { ValidationText(message: problem) }
          if let image = ImageCatalog.images.first(where: { $0.reference == trimmedReference }) {
            FieldHint("\(image.displayName) · \(image.flavor.summary) · about \(image.approximateDownloadGB) GB")
          }
        }
        SheetFormRow("Registry") {
          Toggle("Connect over insecure HTTP", isOn: $insecure)
        }
        SheetFormRow("Concurrency") {
          NumberStepperField(title: "Concurrency", value: $concurrency, range: 1...32, unit: "connections")
        }
        SheetFormRow("Layers") {
          Toggle("Reuse layers from similar cached images", isOn: $deduplicate)
        }
      }
      SheetNote(
        .info,
        model.settings.disableAutoPrune
          ? "Interrupted pulls resume where they left off. Automatic pruning is off, so make sure there is enough free space."
          : "Interrupted pulls resume where they left off. If space runs low, Tart removes the least recently used cached images to make room.")
    }
    .frame(width: 600, height: 400)
    .onAppear { referenceFocused = true }
  }

  private var trimmedReference: String { reference.trimmingCharacters(in: .whitespaces) }

  private var command: TartCommand {
    .pull(
      PullOptions(
        remoteName: trimmedReference.isEmpty ? "<image>" : trimmedReference, insecure: insecure,
        concurrency: concurrency, deduplicate: deduplicate))
  }

  private var problem: String? { ReferenceValidation.problem(with: trimmedReference) }

  private func submit() {
    guard problem == nil else { return }
    let navigation = model.navigation
    model.library.performInBackground(command, title: "Pull \(ReferenceValidation.suggestedLocalName(for: trimmedReference))") {
      navigation.selection = .images
    }
    navigation.selection = .activity
    dismiss()
  }
}
