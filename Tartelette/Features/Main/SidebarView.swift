import SwiftUI
import TarteletteKit

/// Dashboard, the VM list and the library sections.
struct SidebarView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var navigation = model.navigation
    let vms = filteredVMs

    List(selection: $navigation.selection) {
      Section {
        Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent")
          .tag(SidebarItem.dashboard)
      }

      Section("Virtual Machines") {
        ForEach(vms) { vm in
          VMRow(vm: vm)
            .tag(SidebarItem.vm(vm.name))
            .contextMenu { VMActionsMenu(name: vm.name) }
        }
        if vms.isEmpty {
          if model.library.vms.isEmpty {
            Button {
              model.navigation.present(.newVM(initialTab: .image))
            } label: {
              Label("New Virtual Machine…", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
          } else {
            Text("No matches").foregroundStyle(.secondary)
          }
        }
      }

      Section("Library") {
        Label("Images", systemImage: "square.stack.3d.up")
          .badge(model.library.images.count)
          .tag(SidebarItem.images)
        Label("Registries", systemImage: "key")
          .tag(SidebarItem.registries)
        Label("Storage", systemImage: "internaldrive")
          .tag(SidebarItem.storage)
        Label("Activity", systemImage: "list.bullet.rectangle")
          .badge(model.jobs.activeCount)
          .tag(SidebarItem.activity)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HostFooter()
    }
  }

  private var filteredVMs: [VMListing] {
    let query = model.navigation.searchText.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return model.library.vms }
    return model.library.vms.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }
}

/// Compact host utilisation shown under the sidebar.
private struct HostFooter: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let host = model.metrics.latestHost {
      VStack(spacing: 6) {
        Divider()
        HStack(spacing: 12) {
          FooterMeter(title: "CPU", fraction: host.cpuPercent / 100, tint: .accentColor)
          FooterMeter(
            title: "Memory", fraction: Double(host.memoryUsedBytes) / Double(max(host.memoryTotalBytes, 1)),
            tint: host.memoryPressure.tint)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Mac CPU \(Formatting.percent(host.cpuPercent)), memory \(Formatting.memory(host.memoryUsedBytes)) used")
    }
  }
}

private struct FooterMeter: View {
  let title: String
  let fraction: Double
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(title)
        Spacer()
        Text(Formatting.percent(fraction * 100)).monospacedDigit()
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      ProgressView(value: min(max(fraction, 0), 1))
        .progressViewStyle(.linear)
        .tint(tint)
        .controlSize(.mini)
    }
  }
}
