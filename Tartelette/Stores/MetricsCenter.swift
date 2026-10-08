import AppKit
import Foundation
import Observation
import TarteletteKit

/// Live host, VM and guest metrics with in-memory history, plus Tart storage usage.
///
/// Host and VM samples are taken every `settings.metricsInterval` seconds; guest metrics (from
/// inside the VM, through the guest agent) every 5 s; storage every minute or on demand.
@Observable
final class MetricsCenter {
  private(set) var host: MetricsHistory<HostSample>
  private(set) var vmHistories: [String: MetricsHistory<VMResourceSample>] = [:]
  private(set) var guestHistories: [String: MetricsHistory<GuestSample>] = [:]
  private(set) var guestErrors: [String: String] = [:]
  private(set) var storage: StorageUsage?
  private(set) var isMeasuringStorage = false
  /// Allocated bytes per local VM directory (from the last storage measurement).
  private(set) var vmAllocatedBytes: [String: UInt64] = [:]

  private let context: TartContext
  private let settings: AppSettings
  private let library: VMLibrary
  private let clipboard: ClipboardCenter
  private let hostSampler = HostMetricsSampler()
  private let storageInspector = StorageInspector()
  private var vmSampler: VMMetricsSampler?
  private var samplerHome: URL?
  private var sampleTask: Task<Void, Never>?
  private var guestTask: Task<Void, Never>?
  private var storageTask: Task<Void, Never>?

  init(context: TartContext, settings: AppSettings, library: VMLibrary, clipboard: ClipboardCenter) {
    self.context = context
    self.settings = settings
    self.library = library
    self.clipboard = clipboard
    host = MetricsHistory(capacity: Self.capacity(settings))
  }

  private static func capacity(_ settings: AppSettings) -> Int {
    max(30, Int(Double(settings.historyMinutes * 60) / max(0.5, settings.metricsInterval)))
  }

  // MARK: Queries

  var latestHost: HostSample? { host.latest }
  func latest(for name: String) -> VMResourceSample? { vmHistories[name]?.latest }
  func history(for name: String) -> [VMResourceSample] { vmHistories[name]?.samples ?? [] }
  func latestGuest(for name: String) -> GuestSample? { guestHistories[name]?.latest }
  func guestHistory(for name: String) -> [GuestSample] { guestHistories[name]?.samples ?? [] }

  /// The host processes backing a VM (tart + Virtualization service).
  func processes(for name: String) async -> VMProcessSet? {
    await sampler()?.processes(forVM: name)
  }

  // MARK: Sampling

  func start() {
    stop()
    sampleTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.sampleOnce()
        try? await Task.sleep(for: .seconds(max(0.5, self.settings.metricsInterval)))
      }
    }
    guestTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self else { return }
        await self.sampleGuests()
      }
    }
    storageTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refreshStorage()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  func stop() {
    sampleTask?.cancel()
    guestTask?.cancel()
    storageTask?.cancel()
    sampleTask = nil
    guestTask = nil
    storageTask = nil
  }

  /// Applies a changed history length or interval.
  func settingsChanged() {
    let capacity = Self.capacity(settings)
    guard capacity != host.capacity else { return }
    host = Self.resized(host, to: capacity)
    vmHistories = vmHistories.mapValues { Self.resized($0, to: capacity) }
  }

  private static func resized<S>(_ history: MetricsHistory<S>, to capacity: Int) -> MetricsHistory<S> {
    var copy = MetricsHistory<S>(capacity: capacity)
    for sample in history.samples { copy.append(sample) }
    return copy
  }

  private func sampler() -> VMMetricsSampler? {
    guard context.environment != nil else { return nil }
    let home = context.paths.home
    if samplerHome != home || vmSampler == nil {
      vmSampler = VMMetricsSampler(paths: context.paths)
      samplerHome = home
    }
    return vmSampler
  }

  private func sampleOnce() async {
    let hostSample = await hostSampler.sample()
    host.append(hostSample)

    let running = library.runningVMs.map(\.name)
    guard let sampler = sampler() else { return }
    let samples = await sampler.sample(vms: running)
    let capacity = host.capacity
    for (name, sample) in samples {
      var history = vmHistories[name] ?? MetricsHistory(capacity: capacity)
      history.append(sample)
      vmHistories[name] = history
    }
  }

  private func sampleGuests() async {
    guard settings.guestMetricsEnabled else { return }
    for vm in library.runningVMs {
      guard let endpoint = clipboard.endpoint(for: vm.name) else { continue }
      do {
        let sample = try await GuestMetricsCollector.sample(endpoint)
        var history = guestHistories[vm.name] ?? MetricsHistory(capacity: 720)
        history.append(sample)
        guestHistories[vm.name] = history
        guestErrors[vm.name] = nil
      } catch {
        guestErrors[vm.name] = error.localizedDescription
      }
    }
  }

  /// Measures TART_HOME (allocated bytes, so sparse disks count what they really use).
  func refreshStorage() async {
    guard context.environment != nil, !isMeasuringStorage else { return }
    isMeasuringStorage = true
    defer { isMeasuringStorage = false }
    let paths = context.paths
    storage = await storageInspector.usage(paths: paths)
    var sizes: [String: UInt64] = [:]
    for vm in library.vms {
      sizes[vm.name] = await storageInspector.allocatedSize(of: paths.vmDirectory(vm.name))
    }
    vmAllocatedBytes = sizes
  }

  /// Drops histories of VMs that no longer exist.
  func handle(_ changes: [VMStateChange]) {
    for change in changes where change.newState == nil {
      vmHistories[change.name] = nil
      guestHistories[change.name] = nil
      guestErrors[change.name] = nil
    }
    if changes.contains(where: { $0.oldState == nil || $0.newState == nil }) {
      Task { await refreshStorage() }
    }
  }
}
