import AppKit
import SwiftUI
import TarteletteKit

/// The menu bar extra panel: host meters, VMs with quick actions, running jobs.
struct MenuBarContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
      Divider()

      if model.context.isAvailable {
        vmList
      } else {
        Text("Tart isn't installed.")
          .foregroundStyle(.secondary)
          .padding(14)
      }

      if !model.jobs.activeJobs.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.jobs.activeJobs.prefix(3)) { job in
            MenuBarJobRow(job: job)
          }
        }
        .padding(14)
      }

      Divider()
      footer
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
    .frame(width: 340)
    .onAppear {
      model.navigation.openMainWindow = { [openWindow] in
        openWindow(id: "main")
        NSApp.activate()
      }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image("BrandMark")
        .resizable()
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 0) {
        Text("Tartelette").font(.headline)
        Text(statusLine).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let host = model.metrics.latestHost {
        VStack(alignment: .trailing, spacing: 3) {
          MiniMeter(title: "CPU", fraction: host.cpuPercent / 100, tint: .accentColor)
          MiniMeter(
            title: "MEM", fraction: Double(host.memoryUsedBytes) / Double(max(host.memoryTotalBytes, 1)),
            tint: host.memoryPressure.tint)
        }
      }
    }
  }

  private var statusLine: String {
    let running = model.library.runningCount
    if running == 0 { return "No VMs running" }
    return running == 1 ? "1 VM running" : "\(running) VMs running"
  }

  @ViewBuilder private var vmList: some View {
    if model.library.vms.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("No virtual machines yet.").foregroundStyle(.secondary)
        Button("New Virtual Machine…") { model.navigation.present(.newVM(initialTab: .image)) }
      }
      .padding(14)
    } else {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(sortedVMs) { vm in
            MenuBarVMRow(vm: vm)
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 320)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var sortedVMs: [VMListing] {
    model.library.vms.sorted { lhs, rhs in
      if lhs.state.isRunning != rhs.state.isRunning { return lhs.state.isRunning }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  private var footer: some View {
    HStack {
      Button("Open Tartelette") {
        model.navigation.openMainWindow()
      }
      .keyboardShortcut("o")
      Spacer()
      Button {
        openSettings()
        NSApp.activate()
      } label: {
        Image(systemName: "gearshape")
      }
      .help("Settings")
      .accessibilityLabel("Settings")
      Button {
        NSApp.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .help("Quit Tartelette")
      .accessibilityLabel("Quit Tartelette")
      .keyboardShortcut("q")
    }
    .buttonStyle(.borderless)
    .controlSize(.regular)
  }
}

private struct MenuBarVMRow: View {
  let vm: VMListing
  @Environment(AppModel.self) private var model
  @State private var isHovered = false

  var body: some View {
    let library = model.library
    let running = vm.state.isRunning
    let sample = model.metrics.latest(for: vm.name)

    HStack(spacing: 10) {
      OSIcon(os: library.os(of: vm.name), size: 22)
      VStack(alignment: .leading, spacing: 0) {
        Text(vm.name).lineLimit(1)
        Text(running ? (sample.map { "CPU \(Formatting.cpu($0.cpuPercent)) · \(Formatting.memory($0.memoryBytes))" } ?? "Running") : vm.state.title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer(minLength: 6)
      if running {
        Group {
          Button { library.showWindow(vm.name) } label: { Image(systemName: "macwindow") }
            .help("Show window")
            .accessibilityLabel("Show window of \(vm.name)")
          Button {
            Task { await model.clipboard.sendHostClipboard(to: vm.name) }
          } label: {
            Image(systemName: "arrow.right.doc.on.clipboard")
          }
          .help("Send the Mac clipboard to \(vm.name)")
          .accessibilityLabel("Send clipboard to \(vm.name)")
          Button { library.requestShutdown(vm.name) } label: { Image(systemName: "power") }
            .help("Shut down")
            .accessibilityLabel("Shut down \(vm.name)")
        }
        .buttonStyle(.borderless)
      } else {
        Button { library.start(vm.name) } label: { Image(systemName: "play.fill") }
          .buttonStyle(.borderless)
          .help("Start \(vm.name)")
          .accessibilityLabel("Start \(vm.name)")
      }
      StatusDot(state: vm.state)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(count: 2) { model.navigation.show(vm.name) }
    .contextMenu { VMActionsMenu(name: vm.name) }
  }
}

private struct MenuBarJobRow: View {
  let job: Job

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(job.title).font(.caption).lineLimit(1)
        Spacer()
        Button {
          job.cancel()
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Cancel")
        .accessibilityLabel("Cancel \(job.title)")
      }
      if let progress = job.progress {
        ProgressView(value: progress).controlSize(.small)
      } else {
        ProgressView().progressViewStyle(.linear).controlSize(.small)
      }
    }
  }
}

private struct MiniMeter: View {
  let title: String
  let fraction: Double
  let tint: Color

  var body: some View {
    HStack(spacing: 5) {
      Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(tint).frame(width: 52 * min(max(fraction, 0), 1))
      }
      .frame(width: 52, height: 5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title) \(Formatting.percent(fraction * 100))")
  }
}
