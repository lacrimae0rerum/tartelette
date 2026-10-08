import SwiftUI
import TarteletteKit

/// Live charts of what a VM costs the host (CPU, memory, disk, power) and, when the guest agent
/// is reachable, what the guest itself reports.
struct VMPerformanceTab: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model
  @AppStorage("vmDetail.performanceWindow") private var window: Int = 300

  private static let windows: [(seconds: Int, title: String)] = [(60, "1 min"), (300, "5 min"), (900, "15 min")]

  var body: some View {
    let history = model.metrics.history(for: vm.name)

    if !vm.state.isRunning, history.isEmpty {
      EmptyStateView(
        "No Performance Data", systemImage: "chart.xyaxis.line",
        message: "Start the VM to see how much CPU, memory, disk and power it uses on this Mac."
      ) {
        Button("Start") { model.library.start(vm.name) }
          .buttonStyle(.borderedProminent)
      }
    } else {
      DetailScroll {
        HStack {
          Text("Host usage")
            .font(.title3.weight(.semibold))
          if !vm.state.isRunning {
            Pill(title: "Last run", systemImage: "clock.arrow.circlepath")
          }
          Spacer()
          Picker("Time range", selection: $window) {
            ForEach(Self.windows, id: \.seconds) { option in
              Text(option.title).tag(option.seconds)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }

        if history.count < 2 {
          InlineNotice(.info, "Collecting samples… charts fill in within a few seconds.")
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16)], spacing: 16) {
          CPUChartCard(vmName: vm.name, history: history, window: TimeInterval(window))
          MemoryChartCard(vmName: vm.name, history: history, window: TimeInterval(window))
          DiskChartCard(history: history, window: TimeInterval(window))
          PowerChartCard(history: history, window: TimeInterval(window))
        }

        GuestPanel(vm: vm, window: TimeInterval(window))
      }
    }
  }
}

// MARK: - Host charts

/// Current / average / peak of a series over the visible window.
private struct SeriesStats: View {
  let values: [Double]
  let formatter: (Double) -> String

  var body: some View {
    HStack(spacing: 14) {
      stat("Now", values.last)
      stat("Average", values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
      stat("Peak", values.max())
    }
    .font(.caption)
  }

  private func stat(_ title: String, _ value: Double?) -> some View {
    HStack(spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      Text(value.map(formatter) ?? "—").monospacedDigit().fontWeight(.medium)
    }
  }
}

private func recent(_ history: [VMResourceSample], window: TimeInterval) -> [VMResourceSample] {
  let start = Date.now.addingTimeInterval(-window)
  return history.filter { $0.date >= start }
}

private struct CPUChartCard: View {
  let vmName: String
  let history: [VMResourceSample]
  let window: TimeInterval
  @Environment(AppModel.self) private var model

  var body: some View {
    let vCPUs = model.library.config(of: vmName)?.cpuCount ?? 1
    let visible = recent(history, window: window)

    SectionCard("CPU", systemImage: "cpu") {
      SeriesStats(values: visible.map(\.cpuPercent), formatter: Formatting.cpu)
    } content: {
      TimeSeriesChart(
        series: [
          ChartSeries(
            name: "Guest", color: .accentColor,
            points: history.map { ChartPoint(date: $0.date, value: $0.guestCPUPercent) }),
          ChartSeries(
            name: "Tart", color: .teal,
            points: history.map { ChartPoint(date: $0.date, value: $0.tartCPUPercent) }),
        ],
        window: window,
        stacked: true,
        rule: (Double(vCPUs) * 100, "\(vCPUs) vCPUs"),
        valueFormatter: Formatting.cpu
      )
      .frame(height: 180)
      Text("100% is one fully busy core. “Tart” covers the window, networking and I/O plumbing.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct MemoryChartCard: View {
  let vmName: String
  let history: [VMResourceSample]
  let window: TimeInterval
  @Environment(AppModel.self) private var model

  var body: some View {
    let assigned = model.library.config(of: vmName).map { Double($0.memorySize) }
    let visible = recent(history, window: window)

    SectionCard("Memory", systemImage: "memorychip") {
      SeriesStats(values: visible.map { Double($0.memoryBytes) }, formatter: { Formatting.memory(UInt64($0)) })
    } content: {
      TimeSeriesChart(
        series: [
          ChartSeries(
            name: "Memory", color: .green,
            points: history.map { ChartPoint(date: $0.date, value: Double($0.memoryBytes)) })
        ],
        window: window,
        yMax: assigned.map { $0 * 1.08 },
        rule: assigned.map { ($0, "\(Formatting.memory(UInt64($0))) assigned") },
        valueFormatter: { Formatting.memory(UInt64(max(0, $0))) }
      )
      .frame(height: 180)
      Text("Physical memory the VM occupies on this Mac. Guests claim memory as they touch it.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct DiskChartCard: View {
  let history: [VMResourceSample]
  let window: TimeInterval

  var body: some View {
    let visible = recent(history, window: window)

    SectionCard("Disk Activity", systemImage: "internaldrive") {
      SeriesStats(
        values: visible.map { $0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond }, formatter: Formatting.rate)
    } content: {
      TimeSeriesChart(
        series: [
          ChartSeries(
            name: "Read", color: .blue,
            points: history.map { ChartPoint(date: $0.date, value: $0.diskReadBytesPerSecond) }),
          ChartSeries(
            name: "Write", color: .pink,
            points: history.map { ChartPoint(date: $0.date, value: $0.diskWriteBytesPerSecond) }),
        ],
        window: window,
        valueFormatter: Formatting.rate
      )
      .frame(height: 180)
    }
  }
}

private struct PowerChartCard: View {
  let history: [VMResourceSample]
  let window: TimeInterval

  var body: some View {
    let points = history.compactMap { sample in sample.powerWatts.map { ChartPoint(date: sample.date, value: $0) } }
    let visible = recent(history, window: window).compactMap(\.powerWatts)

    SectionCard("Power", systemImage: "bolt") {
      SeriesStats(values: visible, formatter: { Formatting.watts($0) })
    } content: {
      if points.isEmpty {
        Text("macOS doesn't report energy use for these processes.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        TimeSeriesChart(
          series: [ChartSeries(name: "Power", color: .yellow, points: points)],
          window: window,
          valueFormatter: { Formatting.watts($0) }
        )
        .frame(height: 180)
      }
    }
  }
}

// MARK: - Guest

/// Utilisation reported from inside the guest by the Tart Guest Agent.
private struct GuestPanel: View {
  let vm: VMListing
  let window: TimeInterval
  @Environment(AppModel.self) private var model

  var body: some View {
    let metrics = model.metrics
    let latest = metrics.latestGuest(for: vm.name)
    let status = model.clipboard.agentStatus(for: vm.name)

    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Inside the guest")
          .font(.title3.weight(.semibold))
        Spacer()
        if let latest {
          Text("Updated \(Formatting.relative(latest.date))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let latest {
        GuestTiles(sample: latest, history: metrics.guestHistory(for: vm.name))
        let cpu = metrics.guestHistory(for: vm.name).compactMap { sample in
          sample.cpuPercent.map { ChartPoint(date: sample.date, value: $0) }
        }
        if cpu.count > 1 {
          SectionCard("Guest CPU", systemImage: "gauge.with.dots.needle.33percent") {
            Text("Share of all guest CPUs").font(.caption).foregroundStyle(.secondary)
          } content: {
            TimeSeriesChart(
              series: [ChartSeries(name: "Guest CPU", color: .indigo, points: cpu)],
              window: max(window, 300),
              yMax: 100,
              valueFormatter: Formatting.percent
            )
            .frame(height: 140)
          }
        }
        if let error = metrics.guestErrors[vm.name] {
          InlineNotice(.warning, "The last guest reading failed: \(error)")
        }
      } else {
        SectionCard("Guest Metrics", systemImage: "point.3.connected.trianglepath.dotted") {
          unavailableContent(status: status)
        }
      }
    }
  }

  @ViewBuilder
  private func unavailableContent(status: GuestAgentStatus) -> some View {
    if !model.settings.guestMetricsEnabled {
      InlineNotice(
        .info, "Guest metrics are turned off in Settings › Monitoring.", actionTitle: "Open Settings"
      ) { model.navigation.openSettings() }
    } else if !vm.state.isRunning {
      Text("Guest metrics appear while the VM runs.")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if status.isAvailable {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading CPU, memory and disk from inside the guest…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Pill(title: status.title, systemImage: status.systemImage, tint: status.tint)
        Text(
          "Load, memory, disk and uptime from inside the guest need the Tart Guest Agent, which ships with Cirrus Labs base, Xcode and Linux images. \(status.detail)"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct GuestTiles: View {
  let sample: GuestSample
  let history: [GuestSample]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
      MetricTile(
        title: "CPU",
        value: sample.cpuPercent.map(Formatting.percent) ?? "—",
        caption: "Load \(Formatting.loadAverage(sample.loadAverage))",
        systemImage: "gauge.with.dots.needle.33percent",
        tint: .indigo,
        series: history.compactMap(\.cpuPercent),
        seriesMax: 100)
      MetricTile(
        title: "Memory",
        value: sample.memoryUsedBytes.map(Formatting.memory) ?? "—",
        caption: sample.memoryTotalBytes.map { "of \(Formatting.memory($0))" },
        systemImage: "memorychip",
        tint: .green,
        series: history.compactMap { $0.memoryUsedBytes.map(Double.init) },
        seriesMax: sample.memoryTotalBytes.map(Double.init))
      MetricTile(
        title: "Startup Disk",
        value: sample.diskUsedBytes.map(Formatting.bytes) ?? "—",
        caption: diskCaption,
        systemImage: "internaldrive",
        tint: .blue)
      MetricTile(
        title: "Uptime",
        value: sample.uptimeSeconds.map(Formatting.duration) ?? "—",
        caption: sample.processCount.map { "\($0) processes" },
        systemImage: "clock",
        tint: .orange)
    }
  }

  private var diskCaption: String? {
    guard let used = sample.diskUsedBytes, let total = sample.diskTotalBytes, total > 0 else { return nil }
    let free = total > used ? total - used : 0
    return "\(Formatting.bytes(free)) free of \(Formatting.bytes(total))"
  }
}
