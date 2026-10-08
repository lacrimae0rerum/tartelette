import AppKit
import SwiftUI
import TarteletteKit

/// Everything known about a VM at a glance: configuration, network, host processes, guest agent
/// and live utilisation.
struct VMOverviewTab: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    DetailScroll {
      if vm.state.isRunning {
        LiveSummary(name: vm.name)
      }
      HStack(alignment: .top, spacing: 16) {
        VStack(spacing: 16) {
          DetailsCard(vm: vm)
          StorageCard(vm: vm)
        }
        VStack(spacing: 16) {
          NetworkCard(vm: vm)
          GuestAgentCard(vm: vm)
          HostProcessesCard(vm: vm)
        }
      }
    }
  }
}

// MARK: - Live summary

private struct LiveSummary: View {
  let name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let history = model.metrics.history(for: name).suffix(60)
    let latest = history.last
    let config = model.library.config(of: name)
    let vCPUs = Double(config?.cpuCount ?? 1)

    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
      MetricTile(
        title: "CPU",
        value: latest.map { Formatting.cpu($0.cpuPercent) } ?? "—",
        caption: latest.map { "\(Formatting.percent($0.cpuPercent / vCPUs)) of \(Int(vCPUs)) vCPUs" } ?? "Measuring…",
        systemImage: "cpu",
        series: history.map(\.cpuPercent),
        seriesMax: vCPUs * 100)
      MetricTile(
        title: "Memory",
        value: latest.map { Formatting.memory($0.memoryBytes) } ?? "—",
        caption: config.map { "of \(Formatting.memory($0.memorySize)) assigned" },
        systemImage: "memorychip",
        tint: .green,
        series: history.map { Double($0.memoryBytes) },
        seriesMax: config.map { Double($0.memorySize) })
      MetricTile(
        title: "Disk",
        value: latest.map { Formatting.rate($0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond) } ?? "—",
        caption: latest.map { "↓ \(Formatting.rate($0.diskReadBytesPerSecond))  ↑ \(Formatting.rate($0.diskWriteBytesPerSecond))" },
        systemImage: "internaldrive",
        tint: .blue,
        series: history.map { $0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond })
      MetricTile(
        title: "Power",
        value: Formatting.watts(latest?.powerWatts),
        caption: latest?.powerWatts == nil ? "Not reported by macOS" : "Energy used by the VM",
        systemImage: "bolt",
        tint: .yellow,
        series: history.compactMap(\.powerWatts))
    }
  }
}

// MARK: - Details

private struct DetailsCard: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    let config = model.library.config(of: vm.name)
    let os = model.library.os(of: vm.name)

    SectionCard("Details", systemImage: "info.circle") {
      Button("Configure…") { model.navigation.vmDetailTab = .configuration }
        .buttonStyle(.link)
        .disabled(vm.state.isRunning)
    } content: {
      KeyValueGrid(rows: rows(config: config, os: os))
    }
  }

  private func rows(config: VMConfigFile?, os: VMOperatingSystem) -> [KeyValueRow] {
    var rows = [KeyValueRow("State", vm.state.title)]
    let arch = config?.arch.map { " (\($0))" } ?? ""
    rows.append(KeyValueRow("System", os.displayName + arch))
    if let config {
      let minimumCPU = config.cpuCountMin.flatMap { $0 > 1 ? " · minimum \($0)" : nil } ?? ""
      rows.append(KeyValueRow("Processors", "\(config.cpuCount) virtual CPUs" + minimumCPU))
      let minimumMemory = config.memorySizeMin.map { " · minimum \(Formatting.memory($0))" } ?? ""
      rows.append(KeyValueRow("Memory", Formatting.memory(config.memorySize) + minimumMemory))
      rows.append(KeyValueRow("Display", displayDescription(config)))
      if let mac = config.macAddress {
        rows.append(KeyValueRow("MAC address", mac, monospaced: true, accessory: AnyView(CopyButton(value: mac))))
      }
    }
    rows.append(KeyValueRow("Last used", Formatting.relative(vm.lastAccessed)))
    return rows
  }

  private func displayDescription(_ config: VMConfigFile) -> String {
    guard let display = config.display else { return "Default" }
    let unit = display.unit.map { " \($0)" } ?? ""
    let refit =
      switch config.displayRefit {
      case true?: " · resizes with window"
      case false?: " · fixed size"
      case nil: ""
      }
    return "\(display.width) × \(display.height)\(unit)\(refit)"
  }
}

private struct StorageCard: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model

  var body: some View {
    let config = model.library.config(of: vm.name)
    let allocated = model.metrics.vmAllocatedBytes[vm.name]
    let capacityBytes = vm.diskGB.map { $0 * 1_000_000_000 }

    SectionCard("Storage", systemImage: "internaldrive") {
      Button("Show in Finder") { model.library.revealInFinder(vm.name) }
        .buttonStyle(.link)
    } content: {
      VStack(alignment: .leading, spacing: 12) {
        if let capacityBytes, capacityBytes > 0 {
          let used = Double(allocated ?? UInt64((vm.sizeGB ?? 0) * 1_000_000_000))
          MeterBar(
            segments: [MeterSegment(label: "Used on this Mac", value: used, color: .accentColor)],
            total: capacityBytes, height: 10)
        }
        KeyValueGrid(rows: [
          KeyValueRow("Disk size", Formatting.gigabytes(vm.diskGB)),
          KeyValueRow(
            "On this Mac",
            allocated.map(Formatting.bytes) ?? Formatting.gigabytes(vm.sizeGB)),
          KeyValueRow("Format", (config?.diskFormat ?? DiskFormat.raw.rawValue).uppercased()),
          KeyValueRow(
            "Location", model.context.paths.vmDirectory(vm.name).path(percentEncoded: false),
            monospaced: true),
        ])
        Text("Disks are sparse: they only take the space the guest has written.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Network

private struct NetworkCard: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model
  @State private var isResolving = false
  @State private var problem: String?

  var body: some View {
    let profiles = model.profiles
    let resolver = profiles.profile(for: vm.name).ipResolver
    let address = model.library.ipAddresses[vm.name]

    SectionCard("Network", systemImage: "network") {
      Picker("Resolver", selection: Binding(
        get: { resolver },
        set: { value in profiles.update(vm.name) { $0.ipResolver = value } }
      )) {
        Text("DHCP").tag(IPOptions.Resolver.dhcp)
        Text("ARP").tag(IPOptions.Resolver.arp)
        Text("Guest Agent").tag(IPOptions.Resolver.agent)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
      .help(resolverHelp(resolver))
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("IP address").foregroundStyle(.secondary)
          if let address {
            Text(address)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            CopyButton(value: address)
          } else {
            Text(vm.state.isRunning ? "Not resolved yet" : "Available while running")
              .foregroundStyle(.tertiary)
          }
          Spacer()
          if isResolving {
            ProgressView().controlSize(.small)
          }
          Button(address == nil ? "Resolve" : "Refresh") { resolve() }
            .disabled(!vm.state.isRunning || isResolving)
        }
        if let problem {
          Text(problem)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        Text(networkSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .task(id: vm.state) {
      if vm.state.isRunning, model.library.ipAddresses[vm.name] == nil {
        try? await Task.sleep(for: .seconds(1))
        resolve(quietly: true)
      }
    }
  }

  private var networkSummary: String {
    let options = model.library.launchedOptions[vm.name] ?? model.profiles.profile(for: vm.name).options
    switch options.network {
    case .shared: return "Shared network (NAT). Resolve with DHCP."
    case .bridged(let interfaces):
      return "Bridged to \(interfaces.joined(separator: ", ")). Resolve with ARP or the guest agent."
    case .softnet: return "Softnet isolation. Resolve with DHCP or the guest agent."
    case .hostOnly: return "Host-only network. Resolve with DHCP or the guest agent."
    }
  }

  private func resolverHelp(_ resolver: IPOptions.Resolver) -> String {
    switch resolver {
    case .dhcp: "Reads the host's DHCP leases. Fast and reliable, except for bridged networking."
    case .arp: "Reads the host's ARP table. Works with bridged networking once the guest has sent traffic."
    case .agent: "Asks the Tart Guest Agent. Works with any network mode."
    }
  }

  private func resolve(quietly: Bool = false) {
    isResolving = true
    problem = nil
    Task {
      defer { isResolving = false }
      do {
        try await model.library.resolveIP(vm.name, waitSeconds: quietly ? 10 : 5)
      } catch {
        if !quietly { problem = error.localizedDescription }
      }
    }
  }
}

// MARK: - Guest agent

private struct GuestAgentCard: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model
  @State private var isChecking = false

  var body: some View {
    let state = model.clipboard.state(for: vm.name)
    let status = vm.state.isRunning ? state.agentStatus : .unknown

    SectionCard("Guest Agent", systemImage: "point.3.connected.trianglepath.dotted") {
      if vm.state.isRunning {
        Button("Check Now") {
          isChecking = true
          Task {
            await model.clipboard.probe(vm.name)
            isChecking = false
          }
        }
        .buttonStyle(.link)
        .disabled(isChecking || status == .checking)
      }
    } content: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Pill(title: status.title, systemImage: status.systemImage, tint: status.tint)
          if let route = state.route, status.isAvailable {
            Text("via \(route.title)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(vm.state.isRunning ? status.detail : "Checked automatically when the VM starts.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(
          "The Tart Guest Agent powers the console, guest metrics, IP resolution and the clipboard bridge. It's preinstalled in Cirrus Labs base, Xcode and Linux images."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Host processes

private struct HostProcessesCard: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model
  @State private var processes: VMProcessSet?

  var body: some View {
    let library = model.library

    SectionCard("Host Processes", systemImage: "gearshape.2") {
      Button("Show Log") { library.revealLog(vm.name) }
        .buttonStyle(.link)
    } content: {
      if vm.state.isRunning {
        KeyValueGrid(rows: rows)
      } else {
        Text(vm.state == .suspended ? "Suspended: the VM's memory is saved to disk." : "No processes while the VM is stopped.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .task(id: vm.state) {
      guard vm.state.isRunning else {
        processes = nil
        return
      }
      while !Task.isCancelled {
        processes = await model.metrics.processes(for: vm.name)
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private var rows: [KeyValueRow] {
    let library = model.library
    var rows: [KeyValueRow] = []
    if let pid = processes?.tartPID ?? library.pid(of: vm.name) {
      rows.append(KeyValueRow("tart run", "PID \(pid)", monospaced: true))
    }
    if let pids = processes?.virtualMachinePIDs, !pids.isEmpty {
      rows.append(
        KeyValueRow("Virtualization", pids.map { "PID \($0)" }.joined(separator: ", "), monospaced: true))
    } else {
      rows.append(KeyValueRow("Virtualization", "Starting…"))
    }
    if let process = library.launched[vm.name] {
      rows.append(KeyValueRow("Started", Formatting.relative(process.launchedAt)))
      rows.append(
        KeyValueRow(
          "Command", process.commandLine, monospaced: true,
          accessory: AnyView(CopyButton(value: process.commandLine))))
    } else {
      rows.append(KeyValueRow("Started by", "Another app or Terminal"))
    }
    return rows
  }
}

// MARK: - Helpers

/// A tiny borderless copy button with checkmark feedback.
struct CopyButton: View {
  let value: String
  @State private var copied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      withAnimation { copied = true }
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation { copied = false }
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .contentTransition(.symbolEffect(.replace))
        .imageScale(.small)
    }
    .buttonStyle(.borderless)
    .help("Copy")
    .accessibilityLabel("Copy \(value)")
  }
}
