import SwiftUI
import TarteletteKit

/// Host utilisation, running VMs and storage at a glance; a welcome screen when there are no VMs.
struct DashboardView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if model.library.hasLoaded, model.library.vms.isEmpty {
          GetStartedView()
        }
        HostOverviewSection()
        RunningVMsSection()
        StorageSummarySection()
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Dashboard")
    .navigationSubtitle(subtitle)
  }

  private var subtitle: String {
    let running = model.library.runningCount
    let total = model.library.vms.count
    switch (total, running) {
    case (0, _): return "No virtual machines"
    case (1, 0): return "1 VM, not running"
    case (1, _): return "1 VM, running"
    case (_, 0): return "\(total) VMs, none running"
    default: return "\(running) of \(total) VMs running"
    }
  }
}

// MARK: - Host

private struct HostOverviewSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let history = model.metrics.host.samples
    let latest = history.last

    VStack(alignment: .leading, spacing: 10) {
      Text("This Mac").font(.title3.weight(.semibold))
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
        MetricTile(
          title: "CPU",
          value: latest.map { Formatting.percent($0.cpuPercent) } ?? "—",
          caption: latest.map { "\($0.logicalCores) cores · load \(Formatting.loadAverage(Array($0.loadAverage.prefix(1))))" },
          systemImage: "cpu",
          tint: .accentColor,
          series: history.map(\.cpuPercent),
          seriesMax: 100)
        MetricTile(
          title: "Memory",
          value: latest.map { Formatting.memory($0.memoryUsedBytes) } ?? "—",
          caption: latest.map { "of \(Formatting.memory($0.memoryTotalBytes)) · pressure \($0.memoryPressure.title.lowercased())" },
          systemImage: "memorychip",
          tint: latest?.memoryPressure.tint ?? .green,
          series: history.map { Double($0.memoryUsedBytes) },
          seriesMax: latest.map { Double($0.memoryTotalBytes) })
        MetricTile(
          title: "Swap",
          value: latest.map { Formatting.memory($0.swapUsedBytes) } ?? "—",
          caption: latest.map { "Compressed \(Formatting.memory($0.memoryCompressedBytes))" },
          systemImage: "arrow.left.arrow.right.square",
          tint: .purple,
          series: history.map { Double($0.swapUsedBytes) })
        MetricTile(
          title: "Thermal State",
          value: latest?.thermalState.title ?? "—",
          caption: model.metrics.storage.map { "\(Formatting.bytes($0.volumeAvailableBytes)) free on disk" },
          systemImage: "thermometer.medium",
          tint: latest?.thermalState.tint ?? .green)
      }
    }
  }
}

// MARK: - Running VMs

private struct RunningVMsSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let running = model.library.runningVMs

    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Running").font(.title3.weight(.semibold))
        if !running.isEmpty {
          Text("\(running.count)")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      if running.isEmpty {
        if !model.library.vms.isEmpty {
          QuickStartRow()
        }
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
          ForEach(running) { vm in
            RunningVMCard(name: vm.name)
          }
        }
      }
    }
  }
}

/// Start buttons for stopped VMs when nothing runs.
private struct QuickStartRow: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SectionCard("Nothing is running", systemImage: "moon.zzz") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(model.library.vms.prefix(8)) { vm in
            Button {
              model.library.start(vm.name)
            } label: {
              HStack(spacing: 8) {
                OSIcon(os: model.library.os(of: vm.name), size: 20)
                Text(vm.name).lineLimit(1)
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.bordered)
            .help("Start “\(vm.name)”")
          }
        }
      }
    }
  }
}

/// A live card for one running VM.
struct RunningVMCard: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let library = model.library
    let history = model.metrics.history(for: name)
    let latest = history.last
    let config = library.config(of: name)

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        OSIcon(os: library.os(of: name), size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(name).font(.headline).lineLimit(1)
          Text(config.map { "\($0.cpuCount) CPU · \(Formatting.memory($0.memorySize))" } ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          VMActionsMenu(name: name)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(name)")
      }

      HStack(alignment: .firstTextBaseline, spacing: 18) {
        CardStat(title: "CPU", value: latest.map { Formatting.cpu($0.cpuPercent) } ?? "—")
        CardStat(title: "Memory", value: latest.map { Formatting.memory($0.memoryBytes) } ?? "—")
        CardStat(title: "Power", value: Formatting.watts(latest?.powerWatts))
      }

      Sparkline(
        values: history.suffix(120).map(\.cpuPercent),
        tint: .accentColor,
        maxValue: Double((config?.cpuCount ?? 1) * 100))
        .frame(height: 38)

      HStack {
        Button("Show", systemImage: "macwindow") { library.showWindow(name) }
        Button("Details", systemImage: "info.circle") { model.navigation.show(name) }
        Spacer()
        Button("Shut Down", systemImage: "power") { library.requestShutdown(name) }
      }
      .controlSize(.small)
      .buttonStyle(.bordered)
    }
    .padding(14)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    )
    .contextMenu { VMActionsMenu(name: name) }
  }
}

private struct CardStat: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value)
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Storage

private struct StorageSummarySection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SectionCard("Storage", systemImage: "internaldrive") {
      Button("Manage…") { model.navigation.selection = .storage }
        .buttonStyle(.link)
    } content: {
      if let storage = model.metrics.storage {
        MeterBar(
          segments: [
            MeterSegment(label: "VMs", value: Double(storage.vmsBytes), color: .accentColor),
            MeterSegment(label: "OCI cache", value: Double(storage.ociCacheBytes), color: .purple),
            MeterSegment(label: "IPSW cache", value: Double(storage.ipswCacheBytes), color: .teal),
            MeterSegment(label: "Other", value: Double(storage.otherBytes), color: .gray),
          ],
          total: Double(max(storage.volumeTotalBytes, 1)))
        Text(
          "Tart uses \(Formatting.bytes(storage.totalBytes)) in \(storage.tartHome.path(percentEncoded: false)) · "
            + "\(Formatting.bytes(storage.volumeAvailableBytes)) free of \(Formatting.bytes(storage.volumeTotalBytes))")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Measuring…").foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Welcome

/// Shown when there are no VMs yet: recommended images and ways to create a VM.
private struct GetStartedView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        Image("BrandMark")
          .resizable()
          .frame(width: 72, height: 72)
        VStack(alignment: .leading, spacing: 4) {
          Text("Welcome to Tartelette").font(.largeTitle.weight(.semibold))
          Text("Create your first virtual machine. Cirrus Labs images are ready to use — sign in with admin / admin.")
            .foregroundStyle(.secondary)
        }
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
        ForEach(ImageCatalog.recommended) { image in
          CatalogCard(image: image) {
            model.navigation.present(.newVM(initialTab: .image, imageReference: image.reference))
          }
        }
      }

      HStack {
        Button("Create macOS VM from IPSW…", systemImage: "apple.logo") {
          model.navigation.present(.newVM(initialTab: .macOS))
        }
        Button("Create Empty Linux VM…", systemImage: "server.rack") {
          model.navigation.present(.newVM(initialTab: .linux))
        }
        Button("Import…", systemImage: "square.and.arrow.down") { model.navigation.present(.importVM) }
      }
      .buttonStyle(.bordered)
    }
    .padding(20)
    .background(
      LinearGradient(
        colors: [Color.accentColor.opacity(0.12), Color.purple.opacity(0.08)], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

/// A card for one catalog image with a “Get” button.
struct CatalogCard: View {
  let image: CatalogImage
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      OSIcon(os: image.operatingSystem, size: 36)
      VStack(alignment: .leading, spacing: 2) {
        Text(image.displayName).font(.headline).lineLimit(1)
        Text(image.flavor.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Text("≈ \(image.approximateDownloadGB) GB download").font(.caption2).foregroundStyle(.tertiary)
      }
      Spacer(minLength: 4)
      Button("Get", action: action)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    )
  }
}
