import SwiftUI
import TarteletteKit

/// `tart push <local> <remote…>`: uploads a stopped VM (or retags a cached image) to registries.
struct PushSheet: View {
  let vmName: String

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var remoteNames: [String] = []
  @State private var insecure = false
  @State private var concurrency = CloneOptions.defaultConcurrency
  @State private var chunkSizeMB = 0
  @State private var labels: [PushOptions.Label] = []
  @State private var populateCache = false
  @State private var showsAdvanced = false

  var body: some View {
    SheetScaffold(
      title: "Push “\(displayName)”",
      subtitle: isCachedImage ? "Publish this cached image under new names." : "Upload this VM to an OCI registry.",
      systemImage: "icloud.and.arrow.up",
      commandLine: command.previewLine,
      primaryTitle: "Push",
      isPrimaryDisabled: problem != nil,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("Destinations") {
          TokenListEditor(
            title: "",
            tokens: $remoteNames,
            placeholder: placeholder,
            validator: ReferenceValidation.problem(with:))
          FieldHint("One or more references, e.g. “ghcr.io/you/\(ReferenceValidation.suggestedLocalName(for: vmName)):1.0”. Press Return to add.")
        }
        SheetFormRow("Labels") {
          LabelsEditor(labels: $labels)
          FieldHint("Extra metadata stored in the image configuration (--label key=value).")
        }
      }

      DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
        SheetForm {
          SheetFormRow("Registry") {
            Toggle("Connect over insecure HTTP", isOn: $insecure)
          }
          SheetFormRow("Concurrency") {
            NumberStepperField(title: "Concurrency", value: $concurrency, range: 1...32, unit: "connections")
          }
          SheetFormRow("Chunk size") {
            HStack(spacing: 8) {
              NumberStepperField(title: "Chunk size", value: $chunkSizeMB, range: 0...1024, unit: "MB")
              Menu("Presets") {
                Button("Monolithic upload (0)") { chunkSizeMB = 0 }
                Button("GitHub Container Registry (3 MB)") { chunkSizeMB = 3 }
                Button("Amazon ECR (10 MB)") { chunkSizeMB = 10 }
              }
              .fixedSize()
            }
            FieldHint("0 uploads each layer in one request. GHCR needs chunks under 4 MB, ECR over 5 MB; Google doesn't support chunks.")
          }
          SheetFormRow("Cache") {
            Toggle("Keep a copy in the local image cache", isOn: $populateCache)
            FieldHint("Uses more disk space but makes pulling these names later instant (--populate-cache).")
          }
        }
        .padding(.top, 8)
      }

      if model.library.isRunning(vmName) {
        SheetNote(.danger, "“\(vmName)” is running. Shut it down before pushing.")
      } else if !isCachedImage {
        SheetNote(.info, "While the push runs, the VM appears as running and can't be started. Progress shows in Activity.")
      }
    }
    .frame(width: 600, height: showsAdvanced ? 620 : 470)
  }

  private var displayName: String {
    isCachedImage ? ReferenceValidation.suggestedLocalName(for: vmName) : vmName
  }

  private var isCachedImage: Bool { model.library.vm(named: vmName) == nil }

  private var placeholder: String {
    let host = model.registries.accounts.first?.host ?? "ghcr.io"
    return "\(host)/organization/image:tag"
  }

  private var command: TartCommand {
    .push(
      PushOptions(
        localName: vmName, remoteNames: remoteNames.isEmpty ? ["<destination>"] : remoteNames, insecure: insecure,
        concurrency: concurrency, chunkSizeMB: chunkSizeMB,
        labels: labels.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty },
        populateCache: populateCache))
  }

  private var problem: String? {
    if model.library.isRunning(vmName) { return "Stop the VM first." }
    if remoteNames.isEmpty { return "Add at least one destination." }
    if labels.contains(where: { $0.key.contains("=") }) { return "Label keys can't contain “=”." }
    return nil
  }

  private func submit() {
    guard problem == nil else { return }
    model.library.performInBackground(command, title: "Push \(displayName)")
    model.navigation.selection = .activity
    dismiss()
  }
}

/// Edits `key=value` image labels.
private struct LabelsEditor: View {
  @Binding var labels: [PushOptions.Label]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach($labels) { $label in
        HStack(spacing: 6) {
          TextField("Key", text: $label.key)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
          Text("=").foregroundStyle(.secondary)
          TextField("Value", text: $label.value)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
          Button {
            labels.removeAll { $0.id == label.id }
          } label: {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove label")
        }
      }
      Button("Add Label", systemImage: "plus") {
        labels.append(PushOptions.Label(key: "", value: ""))
      }
      .buttonStyle(.borderless)
    }
  }
}
