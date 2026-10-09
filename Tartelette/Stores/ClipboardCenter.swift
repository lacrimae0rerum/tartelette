import AppKit
import Foundation
import Observation
import TarteletteKit

/// One clipboard or file transfer, for the VM's history list.
struct ClipboardEventRecord: Identifiable, Equatable {
  enum Kind: Equatable {
    case sent, received, skipped, failed, info
  }

  let id = UUID()
  let date: Date
  let kind: Kind
  let message: String

  var systemImage: String {
    switch kind {
    case .sent: "arrow.up.circle.fill"
    case .received: "arrow.down.circle.fill"
    case .skipped: "forward.circle"
    case .failed: "exclamationmark.triangle.fill"
    case .info: "info.circle"
    }
  }
}

/// How guest commands reach a VM.
enum GuestRoute: Equatable {
  /// `tart exec` through the Tart Guest Agent (preferred).
  case agent
  /// SSH fallback (guests without the agent), using the address it was probed at.
  case ssh(host: String)

  var title: String {
    switch self {
    case .agent: "Tart Guest Agent"
    case .ssh(let host): "SSH (\(host))"
    }
  }
}

/// Clipboard and guest-connectivity state of one VM.
@Observable
final class VMClipboardState {
  var agentStatus: GuestAgentStatus = .unknown
  var route: GuestRoute?
  var liveSyncEnabled: Bool
  var direction: ClipboardSyncSession.Direction = .bidirectional
  /// Whether a live sync session is currently running.
  fileprivate(set) var isSyncing = false
  fileprivate(set) var isTransferring = false
  fileprivate(set) var lastSent: ClipboardPayload?
  fileprivate(set) var lastReceived: ClipboardPayload?
  fileprivate(set) var events: [ClipboardEventRecord] = []
  fileprivate(set) var lastProbe: Date?

  fileprivate var session: ClipboardSyncSession?
  fileprivate var eventTask: Task<Void, Never>?
  fileprivate var probeTask: Task<Void, Never>?

  init(liveSyncEnabled: Bool) {
    self.liveSyncEnabled = liveSyncEnabled
  }

  fileprivate func record(_ kind: ClipboardEventRecord.Kind, _ message: String) {
    events.insert(ClipboardEventRecord(date: .now, kind: kind, message: message), at: 0)
    if events.count > 50 { events.removeLast(events.count - 50) }
  }
}

/// Guest connectivity (agent probes), live clipboard sync sessions and manual transfers.
///
/// When a VM starts, its agent is probed after a short delay (and retried while unavailable);
/// if the VM's clipboard engine resolves to the bridge and live sync is on, a
/// `ClipboardSyncSession` starts automatically and stops when the VM stops.
@Observable
final class ClipboardCenter {
  private(set) var states: [String: VMClipboardState] = [:]

  private let context: TartContext
  private let settings: AppSettings
  private let profiles: RunProfileStore
  private let library: VMLibrary
  private let navigation: NavigationModel
  let bridge: ClipboardBridge

  init(context: TartContext, settings: AppSettings, profiles: RunProfileStore, library: VMLibrary, navigation: NavigationModel) {
    self.context = context
    self.settings = settings
    self.profiles = profiles
    self.library = library
    self.navigation = navigation
    let staging = URL.cachesDirectory.appendingPathComponent("Tartelette/Clipboard", isDirectory: true)
    bridge = ClipboardBridge(fileStagingDirectory: staging)
  }

  // MARK: Queries

  func state(for name: String) -> VMClipboardState {
    if let state = states[name] { return state }
    let state = VMClipboardState(liveSyncEnabled: settings.liveSyncByDefault)
    states[name] = state
    return state
  }

  func agentStatus(for name: String) -> GuestAgentStatus { states[name]?.agentStatus ?? .unknown }

  /// The clipboard engine in effect for a VM (Automatic resolved by guest OS).
  func engine(for name: String) -> ClipboardEngine {
    profiles.profile(for: name).clipboardEngine.resolved(for: library.os(of: name))
  }

  var activeSessionCount: Int { states.values.filter(\.isSyncing).count }

  /// A guest endpoint over the VM's working route, or nil while it has none.
  func endpoint(for name: String) -> GuestEndpoint? {
    guard let state = states[name], state.agentStatus.isAvailable, let route = state.route else { return nil }
    return makeEndpoint(name, route: route)
  }

  private func makeEndpoint(_ name: String, route: GuestRoute) -> GuestEndpoint? {
    guard let environment = context.environment else { return nil }
    let transport: any GuestTransport =
      switch route {
      case .agent:
        TartExecTransport(
          vmName: name,
          tartExecutable: environment.executable,
          environment: environment.variables(forRun: false),
          runner: context.runner)
      case .ssh(let host):
        SSHTransport(
          host: host, user: settings.sshUsername, password: settings.effectiveSSHPassword, identityFile: nil,
          runner: context.runner)
      }
    return GuestEndpoint(vmName: name, os: library.os(of: name), transport: transport)
  }

  // MARK: Lifecycle

  /// Reacts to VM state changes from `VMLibrary`.
  func handle(_ changes: [VMStateChange]) {
    for change in changes {
      if change.newState?.isRunning == true, change.oldState?.isRunning != true {
        scheduleProbe(change.name, after: .seconds(8))
      } else if change.newState?.isRunning != true {
        tearDown(change.name, forget: change.newState == nil)
      }
    }
  }

  /// Probes VMs that are already running at launch.
  func adoptRunningVMs() {
    for vm in library.runningVMs where states[vm.name]?.agentStatus.isAvailable != true {
      scheduleProbe(vm.name, after: .zero)
    }
  }

  /// Checks the guest agent now (and SSH as a fallback); starts live sync when appropriate.
  func probe(_ name: String) async {
    guard library.isRunning(name) else { return }
    let state = state(for: name)
    state.agentStatus = .checking
    if let endpoint = makeEndpoint(name, route: .agent) {
      let status = await GuestProbe.probe(endpoint.transport)
      if status.isAvailable {
        apply(status, route: .agent, to: name)
        return
      }
      // SSH fallback for guests without the agent (vanilla images with Remote Login enabled).
      if let address = try? await library.resolveIP(name, waitSeconds: 0),
        let sshEndpoint = makeEndpoint(name, route: .ssh(host: address))
      {
        let sshStatus = await GuestProbe.probe(sshEndpoint.transport, timeout: .seconds(8))
        if sshStatus.isAvailable {
          apply(sshStatus, route: .ssh(host: address), to: name)
          return
        }
      }
      apply(status, route: nil, to: name)
    } else {
      apply(.unavailable(reason: "Tart isn't available."), route: nil, to: name)
    }
  }

  private func apply(_ status: GuestAgentStatus, route: GuestRoute?, to name: String) {
    let state = state(for: name)
    let wasAvailable = state.agentStatus.isAvailable
    state.agentStatus = status
    state.route = route
    state.lastProbe = .now
    if status.isAvailable, !wasAvailable {
      state.record(.info, "Connected through \(route?.title ?? "the guest").")
    }
    updateSession(for: name)
  }

  private func scheduleProbe(_ name: String, after delay: Duration) {
    let state = state(for: name)
    state.probeTask?.cancel()
    state.probeTask = Task { [weak self] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      // Retry while unavailable: every 30 s for up to 10 minutes (boot, login, agent start).
      for _ in 0..<20 {
        guard let self, !Task.isCancelled, self.library.isRunning(name) else { return }
        await self.probe(name)
        if self.agentStatus(for: name).isAvailable { return }
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }

  private func tearDown(_ name: String, forget: Bool) {
    guard let state = states[name] else { return }
    state.probeTask?.cancel()
    stopSession(state)
    state.agentStatus = .unknown
    state.route = nil
    if forget { states[name] = nil }
  }

  // MARK: Live sync

  func setLiveSync(_ enabled: Bool, for name: String) {
    state(for: name).liveSyncEnabled = enabled
    updateSession(for: name)
  }

  func setDirection(_ direction: ClipboardSyncSession.Direction, for name: String) {
    let state = state(for: name)
    guard state.direction != direction else { return }
    state.direction = direction
    stopSession(state)
    updateSession(for: name)
  }

  /// Starts or stops the session to match the VM's engine, agent status and live-sync switch.
  func updateSession(for name: String) {
    let state = state(for: name)
    let wanted =
      state.liveSyncEnabled && engine(for: name) == .bridge && state.agentStatus.isAvailable && library.isRunning(name)
    if wanted, state.session == nil, let endpoint = endpoint(for: name) {
      let configuration = ClipboardSyncSession.Configuration(
        direction: state.direction,
        maxAutomaticTransferBytes: max(1, settings.maxAutoTransferMB) * 1024 * 1024,
        includeFiles: settings.syncFiles)
      let session = ClipboardSyncSession(endpoint: endpoint, bridge: bridge, configuration: configuration)
      state.session = session
      state.eventTask = Task { [weak state] in
        for await event in session.events {
          guard let state else { return }
          Self.apply(event, to: state)
        }
      }
      session.start()
      state.isSyncing = true
      state.record(.info, "Live sync on (\(state.direction.title.lowercased())).")
    } else if !wanted, state.session != nil {
      stopSession(state)
      state.record(.info, "Live sync off.")
    }
  }

  private func stopSession(_ state: VMClipboardState) {
    state.session?.stop()
    state.session = nil
    state.eventTask?.cancel()
    state.eventTask = nil
    state.isSyncing = false
  }

  private static func apply(_ event: ClipboardSyncEvent, to state: VMClipboardState) {
    switch event {
    case .sentToGuest(let summary, _):
      state.record(.sent, "Sent \(summary)")
    case .receivedFromGuest(let summary, _):
      state.record(.received, "Received \(summary)")
      // Let the pasteboard settle before reading it back: a reader that lands between
      // `clearContents()` and the end of `writeObjects(_:)` sees a torn, partial clipboard.
      Task { [weak state] in
        try? await Task.sleep(for: .milliseconds(300))
        state?.lastReceived = PasteboardCodec.snapshot()
      }
    case .skipped(let reason):
      state.record(.skipped, reason)
    case .failed(let message):
      state.record(.failed, message)
    case .guestStatus(let status):
      if case .unavailable = status { state.agentStatus = status }
    }
  }

  func stopAll() {
    for state in states.values {
      state.probeTask?.cancel()
      stopSession(state)
    }
  }

  /// Drops every guest connection made under the previous Tart environment and re-probes the
  /// running VMs, so live sync resumes with endpoints built from the new environment.
  func reconnectAll() {
    stopAll()
    for state in states.values {
      state.agentStatus = .unknown
      state.route = nil
    }
    adoptRunningVMs()
  }

  // MARK: Manual transfers

  /// Copies the Mac clipboard into the VM's clipboard now (no size limit).
  func sendHostClipboard(to name: String) async {
    let state = state(for: name)
    if let session = state.session {
      await session.sendNow()
      return
    }
    guard let endpoint = await readyEndpoint(name) else { return }
    guard let payload = PasteboardCodec.snapshot(), !payload.isEmpty else {
      state.record(.skipped, "The Mac clipboard is empty.")
      return
    }
    state.isTransferring = true
    defer { state.isTransferring = false }
    do {
      _ = try await bridge.pushToGuest(payload, endpoint: endpoint)
      state.lastSent = payload
      state.record(.sent, "Sent \(payload.summary)")
    } catch {
      state.record(.failed, error.localizedDescription)
      navigation.show(error: error, title: "Couldn't copy to “\(name)”")
    }
  }

  /// Copies the VM's clipboard onto the Mac clipboard now.
  func fetchGuestClipboard(from name: String) async {
    let state = state(for: name)
    if let session = state.session {
      await session.fetchNow()
      return
    }
    guard let endpoint = await readyEndpoint(name) else { return }
    state.isTransferring = true
    defer { state.isTransferring = false }
    do {
      guard let payload = try await bridge.pullFromGuest(endpoint), !payload.isEmpty else {
        state.record(.skipped, "The VM's clipboard is empty.")
        return
      }
      PasteboardCodec.write(payload)
      state.lastReceived = payload
      state.record(.received, "Received \(payload.summary)")
    } catch {
      state.record(.failed, error.localizedDescription)
      navigation.show(error: error, title: "Couldn't copy from “\(name)”")
    }
  }

  /// Copies host files or folders into a guest folder (default: the guest's Desktop).
  @discardableResult
  func sendFiles(_ files: [URL], to name: String, destination: String = "~/Desktop") async -> [String] {
    guard !files.isEmpty, let endpoint = await readyEndpoint(name) else { return [] }
    let state = state(for: name)
    state.isTransferring = true
    defer { state.isTransferring = false }
    do {
      let paths = try await GuestFileTransfer.send(files, to: endpoint, destination: destination, bridge: bridge)
      let label = files.count == 1 ? files[0].lastPathComponent : "\(files.count) items"
      state.record(.sent, "Copied \(label) to \(destination)")
      return paths
    } catch {
      state.record(.failed, error.localizedDescription)
      navigation.show(error: error, title: "Couldn't copy files to “\(name)”")
      return []
    }
  }

  /// Copies guest files or folders to `~/Downloads/<VM name>` and reveals them in Finder.
  @discardableResult
  func receiveFiles(_ guestPaths: [String], from name: String) async -> [URL] {
    guard !guestPaths.isEmpty, let endpoint = await readyEndpoint(name) else { return [] }
    let state = state(for: name)
    state.isTransferring = true
    defer { state.isTransferring = false }
    let destination = URL.downloadsDirectory.appendingPathComponent(name, isDirectory: true)
    do {
      let urls = try await GuestFileTransfer.receive(guestPaths, from: endpoint, to: destination, bridge: bridge)
      state.record(.received, "Saved \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to Downloads")
      if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
      return urls
    } catch {
      state.record(.failed, error.localizedDescription)
      navigation.show(error: error, title: "Couldn't copy files from “\(name)”")
      return []
    }
  }

  /// An endpoint for a manual action, probing first when the agent hasn't been checked yet.
  private func readyEndpoint(_ name: String) async -> GuestEndpoint? {
    guard library.isRunning(name) else {
      navigation.show(title: "“\(name)” isn't running", message: "Start the VM to exchange clipboard contents or files.")
      return nil
    }
    if endpoint(for: name) == nil { await probe(name) }
    guard let endpoint = endpoint(for: name) else {
      navigation.show(
        title: "Can't reach “\(name)”",
        message: agentStatus(for: name).detail
          + "\n\nCopy and paste needs the Tart Guest Agent (preinstalled in Cirrus Labs base and Xcode images) or SSH access.")
      return nil
    }
    return endpoint
  }
}

extension ClipboardSyncSession.Direction {
  var title: String {
    switch self {
    case .bidirectional: "Both ways"
    case .hostToGuest: "Mac to VM"
    case .guestToHost: "VM to Mac"
    }
  }

  var systemImage: String {
    switch self {
    case .bidirectional: "arrow.left.arrow.right"
    case .hostToGuest: "arrow.right"
    case .guestToHost: "arrow.left"
    }
  }
}
