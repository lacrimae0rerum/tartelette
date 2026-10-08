import SwiftUI
import TarteletteKit

/// `tart prune`: frees space by removing old cache entries or — destructively — old local VMs.
struct PruneSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var entries: PruneOptions.Entries = .caches
  @State private var limitAge = true
  @State private var olderThanDays = 30
  @State private var limitSpace = false
  @State private var spaceBudgetGB = 100
  @State private var garbageCollect = false
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var confirmingVMs = false

  var body: some View {
    SheetScaffold(
      title: "Prune",
      subtitle: "Free disk space used by Tart.",
      systemImage: "scissors",
      commandLine: TartCommand.prune(options).commandLine,
      primaryTitle: entries == .vms ? "Delete VMs…" : "Prune",
      primaryRole: entries == .vms ? .destructive : nil,
      isPrimaryDisabled: !options.hasCriteria,
      isWorking: isWorking,
      errorMessage: errorMessage,
      onPrimary: submit
    ) {
      SheetForm {
        SheetFormRow("Remove") {
          Picker("Remove", selection: $entries) {
            Text("Cached images & IPSWs").tag(PruneOptions.Entries.caches)
            Text("Local virtual machines").tag(PruneOptions.Entries.vms)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        SheetFormRow("Criteria") {
          HStack(spacing: 8) {
            Toggle("Not used for", isOn: $limitAge)
            NumberStepperField(title: "Days", value: $olderThanDays, range: 1...3650, unit: "days")
              .disabled(!limitAge)
          }
          HStack(spacing: 8) {
            Toggle("Keep within", isOn: $limitSpace)
            NumberStepperField(title: "Space budget", value: $spaceBudgetGB, range: 1...65_535, step: 10, unit: "GB")
              .disabled(!limitSpace)
          }
          FieldHint("The space budget keeps the most recently used entries that fit and removes the rest.")
          if entries == .caches {
            Toggle("Also clean up broken tags and unreferenced images", isOn: $garbageCollect)
              .padding(.top, 4)
          }
          if !options.hasCriteria {
            ValidationText(message: "Choose at least one criterion.")
          }
        }
      }

      if entries == .vms {
        SheetNote(
          .danger,
          "This permanently deletes every local VM that isn't running and matches the criteria — disks, settings and suspended state. It can't be undone.",
          title: "Deletes virtual machines")
      }

      estimate
    }
    .frame(width: 600, height: entries == .vms ? 560 : 490)
    .confirmationDialog(
      "Delete \(affected.count == 1 ? "1 virtual machine" : "\(affected.count) virtual machines")?",
      isPresented: $confirmingVMs, titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive, action: run)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(affected.isEmpty ? "No VM matches right now, but Tart will check again." : affected.map(\.name).joined(separator: ", "))
    }
  }

  private var options: PruneOptions {
    PruneOptions(
      entries: entries,
      olderThanDays: limitAge ? olderThanDays : nil,
      spaceBudgetGB: limitSpace ? spaceBudgetGB : nil,
      garbageCollect: entries == .caches && garbageCollect)
  }

  // MARK: Estimate

  private struct Candidate: Identifiable {
    var id: String { name }
    let name: String
    let bytes: UInt64
    let accessed: Date?
  }

  private var candidates: [Candidate] {
    switch entries {
    case .vms:
      return model.library.vms.filter { !$0.state.isRunning }.map { vm in
        Candidate(
          name: vm.name,
          bytes: model.metrics.vmAllocatedBytes[vm.name] ?? UInt64(max(0, (vm.sizeGB ?? 0) * 1e9)),
          accessed: vm.lastAccessed)
      }
    case .caches:
      // Tart lists each pulled image by tag and by digest; count the digest entries once.
      let images = model.library.images
      let digests = images.filter { $0.name.contains("@sha256:") }
      return (digests.isEmpty ? images : digests).map { image in
        Candidate(name: image.name, bytes: UInt64(max(0, (image.sizeGB ?? 0) * 1e9)), accessed: image.lastAccessed)
      }
    }
  }

  /// What the current criteria would remove (Tart decides at run time; this mirrors its rules).
  private var affected: [Candidate] {
    var removed: [String: Candidate] = [:]
    if limitAge {
      let cutoff = Date.now.addingTimeInterval(-Double(olderThanDays) * 86_400)
      for candidate in candidates where (candidate.accessed ?? .distantPast) <= cutoff {
        removed[candidate.name] = candidate
      }
    }
    if limitSpace {
      let budget = UInt64(spaceBudgetGB) * 1_073_741_824
      var used: UInt64 = 0
      for candidate in candidates.sorted(by: { ($0.accessed ?? .distantPast) > ($1.accessed ?? .distantPast) }) {
        used += candidate.bytes
        if used > budget { removed[candidate.name] = candidate }
      }
    }
    return removed.values.sorted { $0.bytes > $1.bytes }
  }

  @ViewBuilder private var estimate: some View {
    if options.hasCriteria, limitAge || limitSpace {
      let affected = affected
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Right now this would remove").font(.subheadline.weight(.medium))
          Spacer()
          Text(affected.isEmpty ? "Nothing" : Formatting.bytes(affected.reduce(0) { $0 + $1.bytes }))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
        if affected.isEmpty {
          FieldHint(entries == .vms ? "No stopped VM matches these criteria." : "No cached image matches these criteria.")
        } else {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(affected.prefix(6)) { candidate in
              HStack {
                Image(systemName: entries == .vms ? "desktopcomputer" : "square.stack.3d.up")
                  .foregroundStyle(.secondary)
                  .frame(width: 18)
                Text(entries == .vms ? candidate.name : ReferenceValidation.suggestedLocalName(for: candidate.name))
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Text(Formatting.relative(candidate.accessed)).foregroundStyle(.secondary)
                Text(Formatting.bytes(candidate.bytes))
                  .monospacedDigit()
                  .frame(width: 80, alignment: .trailing)
              }
              .font(.callout)
            }
            if affected.count > 6 {
              FieldHint("and \(affected.count - 6) more")
            }
          }
        }
        if entries == .caches {
          FieldHint("Cached macOS restore images (IPSWs) are pruned by the same rules.")
        }
      }
      .padding(12)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  // MARK: Actions

  private func submit() {
    guard options.hasCriteria else { return }
    if entries == .vms {
      confirmingVMs = true
    } else {
      run()
    }
  }

  private func run() {
    isWorking = true
    errorMessage = nil
    let command = TartCommand.prune(options)
    Task {
      defer { isWorking = false }
      do {
        try await model.library.perform(command)
        await model.metrics.refreshStorage()
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
