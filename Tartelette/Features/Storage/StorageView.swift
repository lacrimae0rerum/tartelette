import AppKit
import SwiftUI
import TarteletteKit

/// Where Tart's disk space goes: VMs, the image cache and restore images, with pruning.
struct StorageView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        CapacityCard()
        VirtualMachinesCard()
        CachesCard()
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Storage")
    .navigationSubtitle(subtitle)
    .toolbar {
      ToolbarItem {
        Button("Prune…", systemImage: "scissors") { model.navigation.present(.prune) }
          .help("Free space by removing old images or VMs")
      }
      ToolbarItem {
        Button("Show in Finder", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([model.context.paths.home])
        }
        .help("Reveal Tart's folder in Finder")
      }
    }
    .task { await model.metrics.refreshStorage() }
  }

  private var subtitle: String {
    guard let storage = model.metrics.storage else { return "Measuring…" }
    return "Tart uses \(Formatting.bytes(storage.totalBytes))"
  }
}

// MARK: - Capacity

private struct CapacityCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SectionCard("Capacity", systemImage: "internaldrive") {
      HStack(spacing: 8) {
        if model.metrics.isMeasuringStorage {
          ProgressView().controlSize(.small)
        }
        Button {
          Task { await model.metrics.refreshStorage() }
        } label: {
          Label("Measure Again", systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(model.metrics.isMeasuringStorage)
        .help("Measure again")
      }
    } content: {
      if let storage = model.metrics.storage {
        let used = storage.volumeTotalBytes > storage.volumeAvailableBytes
          ? storage.volumeTotalBytes - storage.volumeAvailableBytes : 0
        let otherData = used > storage.totalBytes ? used - storage.totalBytes : 0
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            Text(Formatting.bytes(storage.volumeAvailableBytes))
              .font(.title2.weight(.semibold))
              .monospacedDigit()
            Text("available of \(Formatting.bytes(storage.volumeTotalBytes))")
              .foregroundStyle(.secondary)
            Spacer()
          }
          MeterBar(
            segments: [
              MeterSegment(label: "Virtual machines", value: Double(storage.vmsBytes), color: .accentColor),
              MeterSegment(label: "Images", value: Double(storage.ociCacheBytes), color: .teal),
              MeterSegment(label: "Restore images", value: Double(storage.ipswCacheBytes), color: .purple),
              MeterSegment(label: "Other Tart data", value: Double(storage.otherBytes), color: .indigo),
              MeterSegment(label: "Everything else", value: Double(otherData), color: .gray.opacity(0.55)),
            ],
            total: Double(storage.volumeTotalBytes),
            height: 18)
          HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text((storage.tartHome.path as NSString).abbreviatingWithTildeInPath)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Measuring Tart's folder…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

// MARK: - Virtual machines

private struct VirtualMachinesCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SectionCard("Virtual Machines", systemImage: "desktopcomputer") {
      if let total = model.metrics.storage?.vmsBytes {
        Text(Formatting.bytes(total)).foregroundStyle(.secondary).monospacedDigit()
      }
    } content: {
      if model.library.vms.isEmpty {
        Text("No virtual machines yet.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          HStack {
            Text("Name")
            Spacer()
            Text("On this Mac").frame(width: 200, alignment: .leading)
            Text("Last used").frame(width: 120, alignment: .trailing)
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.bottom, 6)
          ForEach(sortedVMs) { vm in
            Divider()
            VMStorageRow(
              vm: vm, os: model.library.os(of: vm.name),
              allocatedBytes: model.metrics.vmAllocatedBytes[vm.name])
          }
        }
      }
    }
  }

  private var sortedVMs: [VMListing] {
    model.library.vms.sorted {
      (model.metrics.vmAllocatedBytes[$0.name] ?? 0) > (model.metrics.vmAllocatedBytes[$1.name] ?? 0)
    }
  }
}

private struct VMStorageRow: View {
  let vm: VMListing
  let os: VMOperatingSystem
  let allocatedBytes: UInt64?
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      OSIcon(os: os, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(vm.name).fontWeight(.medium)
        StateBadge(state: vm.state).scaleEffect(0.9, anchor: .leading)
      }
      Spacer()
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(allocatedBytes.map(Formatting.bytes) ?? Formatting.gigabytes(vm.sizeGB))
            .monospacedDigit()
          Text("of \(Formatting.gigabytes(vm.diskGB))")
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .tint(fraction > 0.9 ? .orange : .accentColor)
          .accessibilityLabel("Disk allocation")
      }
      .frame(width: 200, alignment: .leading)
      Text(Formatting.relative(vm.lastAccessed))
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 120, alignment: .trailing)
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.navigation.show(vm.name) }
    .contextMenu {
      Button("Show Details") { model.navigation.show(vm.name) }
      Button("Show in Finder") { model.library.revealInFinder(vm.name) }
      Divider()
      Button("Delete…", role: .destructive) { model.navigation.present(.confirmDelete(names: [vm.name])) }
    }
    .accessibilityElement(children: .combine)
  }

  /// Allocated share of the virtual disk's capacity.
  private var fraction: Double {
    guard let capacity = vm.diskGB, capacity > 0 else { return 0 }
    let allocated = allocatedBytes.map(Double.init) ?? (vm.sizeGB ?? 0) * 1e9
    return min(1, allocated / (capacity * 1e9))
  }
}

// MARK: - Caches

private struct CachesCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SectionCard("Caches", systemImage: "archivebox") {
      Button("Prune…") { model.navigation.present(.prune) }
    } content: {
      VStack(alignment: .leading, spacing: 12) {
        CacheRow(
          title: "Images", systemImage: "square.stack.3d.up", tint: .teal,
          detail: imageDetail, bytes: model.metrics.storage?.ociCacheBytes
        ) {
          Button("Show Images") { model.navigation.selection = .images }
        }
        Divider()
        CacheRow(
          title: "Restore images", systemImage: "apple.logo", tint: .purple,
          detail: "macOS IPSW files kept for “Install macOS”.", bytes: model.metrics.storage?.ipswCacheBytes
        ) {
          Button("Show in Finder") {
            let folder = model.context.paths.ipswCache
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : model.context.paths.home)
          }
        }
        Divider()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: model.settings.disableAutoPrune ? "pause.circle" : "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
          Text(
            model.settings.disableAutoPrune
              ? "Automatic pruning is off. Tart won't free cache space on its own when pulling or cloning."
              : "Automatic pruning is on. When space runs low during a pull or clone, Tart removes the least recently used cached images."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Change…") { model.navigation.openSettings() }
        }
      }
    }
  }

  private var imageDetail: String {
    let tagged = model.library.images.filter { !$0.name.contains("@sha256:") }
    let count = tagged.isEmpty ? model.library.images.count : tagged.count
    return count == 0 ? "No downloaded images." : (count == 1 ? "1 downloaded image." : "\(count) downloaded images.")
  }
}

private struct CacheRow<Actions: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  let detail: String
  let bytes: UInt64?
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.medium)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text(bytes.map { $0 == 0 ? "None" : Formatting.bytes($0) } ?? "—")
        .monospacedDigit()
        .foregroundStyle(.secondary)
      actions()
    }
    .accessibilityElement(children: .combine)
  }
}
