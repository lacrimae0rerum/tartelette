import SwiftUI
import TarteletteKit

/// `tart delete <name…>` for local VMs and cached images, with a clear list of what goes away.
struct ConfirmDeleteSheet: View {
  let names: [String]

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var isWorking = false
  @State private var errorMessage: String?

  var body: some View {
    SheetScaffold(
      title: title,
      subtitle: subtitle,
      systemImage: "trash",
      commandLine: TartCommand.delete(names: names).commandLine,
      primaryTitle: "Delete",
      primaryRole: .destructive,
      isPrimaryDisabled: !running.isEmpty || names.isEmpty,
      isWorking: isWorking,
      errorMessage: errorMessage,
      onPrimary: submit
    ) {
      VStack(spacing: 0) {
        ForEach(Array(names.enumerated()), id: \.element) { index, name in
          if index > 0 { Divider() }
          row(for: name)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
      }
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      if !running.isEmpty {
        SheetNote(.danger, "Shut down \(running.map { "“\($0)”" }.joined(separator: ", ")) before deleting.")
      } else if localVMs.isEmpty {
        SheetNote(.info, "Only the local copy is removed. You can pull the image again at any time.")
      } else {
        SheetNote(.warning, "The disk, configuration and suspended state are erased permanently. This can't be undone.")
      }
    }
    .frame(width: 540, height: min(520, 300 + CGFloat(names.count) * 44))
  }

  private var localVMs: [String] { names.filter { model.library.vm(named: $0) != nil } }
  private var running: [String] { names.filter { model.library.isRunning($0) } }

  private var title: String {
    if names.count == 1, let name = names.first {
      return localVMs.isEmpty ? "Delete “\(ReferenceValidation.suggestedLocalName(for: name))”?" : "Delete “\(name)”?"
    }
    return "Delete \(names.count) Items?"
  }

  private var subtitle: String {
    localVMs.isEmpty ? "Remove from the local image cache." : "Deleted VMs don’t go to the Trash."
  }

  @ViewBuilder private func row(for name: String) -> some View {
    HStack(spacing: 10) {
      if let vm = model.library.vm(named: name) {
        OSIcon(os: model.library.os(of: name), size: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(name).fontWeight(.medium)
          Text(detail(for: vm)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        StateBadge(state: vm.state)
      } else {
        Image(systemName: "square.stack.3d.up")
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text(ReferenceValidation.suggestedLocalName(for: name)).fontWeight(.medium)
          Text(name)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        if let image = model.library.images.first(where: { $0.name == name }) {
          Text(Formatting.gigabytes(image.sizeGB)).foregroundStyle(.secondary).monospacedDigit()
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func detail(for vm: VMListing) -> String {
    var parts: [String] = []
    if let bytes = model.metrics.vmAllocatedBytes[vm.name] {
      parts.append("\(Formatting.bytes(bytes)) on disk")
    } else if let size = vm.sizeGB {
      parts.append("\(Formatting.gigabytes(size)) on disk")
    }
    parts.append("used \(Formatting.relative(vm.lastAccessed).lowercased())")
    return parts.joined(separator: " · ")
  }

  private func submit() {
    guard running.isEmpty else { return }
    isWorking = true
    errorMessage = nil
    Task {
      defer { isWorking = false }
      do {
        try await model.library.delete(names)
        await model.metrics.refreshStorage()
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
