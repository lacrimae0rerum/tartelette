import SwiftUI
import TarteletteKit

/// `tart clone <source> <new-name>` for a local VM, a cached image or a remote reference.
struct CloneSheet: View {
  let source: String

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var nameEdited = false
  @State private var replaceExisting = false
  @State private var insecure = false
  @State private var concurrency = CloneOptions.defaultConcurrency
  @State private var deduplicate = false
  @State private var stacked = false
  @State private var pruneLimitGB = CloneOptions.defaultPruneLimitGB
  @State private var showsAdvanced = false
  @State private var isWorking = false
  @State private var errorMessage: String?

  var body: some View {
    SheetScaffold(
      title: "Clone “\(displaySource)”",
      subtitle: isRemote ? "Create a local VM from this image." : "Make an independent copy of this VM.",
      systemImage: "plus.square.on.square",
      commandLine: previewCommand.previewLine,
      primaryTitle: isRemote && !isCached ? "Download & Clone" : "Clone",
      isPrimaryDisabled: problem != nil,
      isWorking: isWorking,
      errorMessage: errorMessage,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("Source") {
          HStack(spacing: 8) {
            if let vm = model.library.vm(named: source) {
              OSIcon(os: model.library.os(of: source), size: 20)
              Text(source).fontWeight(.medium)
              StateBadge(state: vm.state)
            } else {
              Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
              Text(source)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
          }
        }
        SheetFormRow("New name") {
          TextField("VM name", text: nameBinding)
            .textFieldStyle(.roundedBorder)
          if let issue = VMNameValidation.problem(with: name) {
            ValidationText(message: issue)
          } else if model.library.vm(named: name) != nil {
            if model.library.isRunning(name) {
              ValidationText(message: "“\(name)” exists and is running. Choose another name.")
            } else {
              ValidationText(message: replaceExisting ? nil : "A VM named “\(name)” already exists.")
              Toggle("Replace the existing VM (--overwrite)", isOn: $replaceExisting)
                .toggleStyle(.checkbox)
            }
          }
        }
      }

      if isRemote {
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
          SheetForm {
            SheetFormRow("Registry") {
              Toggle("Connect over insecure HTTP", isOn: $insecure)
            }
            SheetFormRow("Concurrency") {
              NumberStepperField(title: "Concurrency", value: $concurrency, range: 1...32, unit: "connections")
            }
            SheetFormRow("Layers") {
              Toggle("Reuse layers from similar cached images", isOn: $deduplicate)
            }
            SheetFormRow("Disk") {
              Toggle("Stacked disk on an immutable base", isOn: $stacked)
                .disabled(!HostOS.supportsStackedDisks)
              FieldHint(
                HostOS.supportsStackedDisks
                  ? "Only for remote macOS images (--stacked)."
                  : "Stacked disks need macOS 27.")
            }
            SheetFormRow("Auto-prune") {
              NumberStepperField(title: "Prune limit", value: $pruneLimitGB, range: 0...4096, step: 10, unit: "GB")
            }
          }
          .padding(.top, 8)
        }
      }

      if isRemote {
        SheetNote(
          .info,
          isCached
            ? "The image is already downloaded, so cloning is quick."
            : "The image is downloaded first; progress appears in Activity.")
      } else {
        SheetNote(
          .info,
          "Thanks to APFS copy-on-write, the clone takes almost no extra space until the two VMs diverge. The copy gets a new MAC address.")
        if model.library.isRunning(source) {
          SheetNote(.warning, "“\(source)” is running. Its disk is copied as it is right now; stop it first for a consistent copy.")
        }
      }
    }
    .frame(width: 560, height: isRemote ? (showsAdvanced ? 580 : 390) : 370)
    .onAppear {
      guard name.isEmpty else { return }
      let base = isRemote ? ReferenceValidation.suggestedLocalName(for: source) : "\(source)-copy"
      name = model.library.uniqueName(basedOn: base)
    }
  }

  private var isRemote: Bool { model.library.vm(named: source) == nil && ReferenceValidation.isRemote(source) }
  private var isCached: Bool { model.library.images.contains { $0.name == source } }
  private var displaySource: String { isRemote ? ReferenceValidation.suggestedLocalName(for: source) : source }

  private var command: TartCommand {
    let overwrite = replaceExisting && model.library.vm(named: name) != nil
    return isRemote
      ? .clone(
        CloneOptions(
          source: source, newName: name, insecure: insecure, concurrency: concurrency, deduplicate: deduplicate,
          stacked: stacked, overwrite: overwrite, pruneLimitGB: pruneLimitGB))
      : .clone(CloneOptions(source: source, newName: name, overwrite: overwrite))
  }

  private var previewCommand: TartCommand {
    guard case .clone(var options) = command else { return command }
    options.newName = previewValue(options.newName, "new-name")
    return .clone(options)
  }

  private var problem: String? {
    if name == source { return "Choose a different name." }
    if let issue = model.library.problemWithNewName(name, allowExisting: replaceExisting) { return issue }
    if model.library.isRunning(name) { return "Stop “\(name)” before replacing it." }
    return nil
  }

  private var nameBinding: Binding<String> {
    Binding(get: { name }, set: { name = $0; nameEdited = true })
  }

  private func submit() {
    guard problem == nil else { return }
    errorMessage = nil
    let newName = name
    let navigation = model.navigation
    if isRemote && !isCached {
      model.library.performInBackground(command, title: "Clone \(displaySource) → \(newName)") { navigation.show(newName) }
      navigation.selection = .activity
      dismiss()
      return
    }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        try await model.library.perform(command)
        navigation.show(newName, tab: .overview)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
