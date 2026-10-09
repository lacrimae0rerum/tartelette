import AppKit
import Foundation
import Observation
import TarteletteKit

/// A VM appeared, disappeared or changed state between two refreshes.
nonisolated struct VMStateChange: Equatable {
  let name: String
  /// nil when the VM is new.
  let oldState: VMState?
  /// nil when the VM was deleted or renamed away.
  let newState: VMState?
}

/// The local VMs and cached images, their configuration, and every VM action.
///
/// State comes from polling `tart list --format json` and reading each VM's `config.json`
/// (never `tart get`, which bumps access dates and skews `tart prune`). Sheets run Tart commands
/// through `perform(_:)` (await the result, then dismiss) or `performInBackground(_:)`
/// (long operations: dismiss immediately, progress shows in Activity).
@Observable
final class VMLibrary {
  private(set) var vms: [VMListing] = []
  private(set) var images: [VMListing] = []
  private(set) var configs: [String: VMConfigFile] = [:]
  /// `tart run` processes started by this app, by VM name.
  private(set) var launched: [String: RunningVMProcess] = [:]
  /// The options each launched VM was started with.
  private(set) var launchedOptions: [String: RunOptions] = [:]
  /// Running VMs that Tartelette started in an earlier session (matched through the run log).
  private(set) var adoptedLaunches: Set<String> = []
  /// VNC URLs printed by `tart run --vnc*`.
  private(set) var vncURLs: [String: URL] = [:]
  /// Last resolved IP address per VM.
  private(set) var ipAddresses: [String: String] = [:]
  private(set) var isRefreshing = false
  private(set) var hasLoaded = false
  private(set) var lastError: String?
  private(set) var lastRefresh: Date?
  /// Number of listing attempts applied so far (successful or not); see `refreshAndWait()`.
  private(set) var listGeneration = 0

  /// Observers notified after each refresh that changed something (ClipboardCenter, MetricsCenter,
  /// Dock badge).
  var onChange: [([VMStateChange]) -> Void] = []

  private let context: TartContext
  private let settings: AppSettings
  private let profiles: RunProfileStore
  private let jobs: JobCenter
  private let navigation: NavigationModel
  private var pollTask: Task<Void, Never>?
  private var refreshPending = false
  private var watcher: DirectoryWatcher?

  init(context: TartContext, settings: AppSettings, profiles: RunProfileStore, jobs: JobCenter, navigation: NavigationModel) {
    self.context = context
    self.settings = settings
    self.profiles = profiles
    self.jobs = jobs
    self.navigation = navigation
  }

  // MARK: Queries

  var runningVMs: [VMListing] { vms.filter(\.state.isRunning) }
  var runningCount: Int { runningVMs.count }

  func vm(named name: String) -> VMListing? { vms.first { $0.name == name } }
  func config(of name: String) -> VMConfigFile? { configs[name] }
  func os(of name: String) -> VMOperatingSystem { configs[name]?.operatingSystem ?? .unknown }
  func state(of name: String) -> VMState { vm(named: name)?.state ?? .stopped }
  func isRunning(_ name: String) -> Bool { state(of: name).isRunning }

  /// The PID holding the VM lock (the `tart run` process), wherever it was started.
  func pid(of name: String) -> Int32? { VMLock.holderPID(vmNamed: name, paths: context.paths) }

  /// `~/Library/Logs/Tartelette/<name>.log`, where `tart run` output goes.
  func logFile(for name: String) -> URL {
    URL.libraryDirectory
      .appendingPathComponent("Logs/Tartelette", isDirectory: true)
      .appendingPathComponent("\(name).log")
  }

  /// Whether `tart suspend` is safe: Tart kills VMs that weren't started with `--suspendable`.
  func canSuspend(_ name: String) -> Bool {
    guard isRunning(name), os(of: name) == .macOS else { return false }
    return launchedOptions[name]?.suspendable ?? profiles.profile(for: name).options.suspendable
  }

  // MARK: Refreshing

  func startPolling() {
    pollTask?.cancel()
    installWatcher()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        let base = max(1, self.settings.refreshInterval)
        let interval = NSApp.isActive ? base : base * 3
        try? await Task.sleep(for: .seconds(interval))
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    watcher = nil
  }

  /// Requests a refresh soon; coalesces with one already in flight.
  func refreshSoon(after delay: Duration = .zero) {
    Task {
      if delay > .zero { try? await Task.sleep(for: delay) }
      await refresh()
    }
  }

  func refresh() async {
    guard let client = context.client else {
      applyListing([], configs: [:])
      hasLoaded = true
      listGeneration += 1
      return
    }
    guard !isRefreshing else {
      refreshPending = true
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    repeat {
      refreshPending = false
      do {
        let listing = try await client.list()
        var newConfigs: [String: VMConfigFile] = [:]
        for vm in listing where vm.source == .local {
          newConfigs[vm.name] = (try? client.configuration(of: vm.name)) ?? configs[vm.name]
        }
        applyListing(listing, configs: newConfigs)
        lastError = nil
      } catch {
        lastError = error.localizedDescription
      }
      hasLoaded = true
      lastRefresh = .now
      listGeneration += 1
    } while refreshPending
  }

  /// Refreshes and returns only after a listing that started after this call has been applied.
  ///
  /// `refresh()` returns at once when another refresh is in flight; callers that must act on the
  /// current environment (for example after TART_HOME changed) need a listing that started later.
  func refreshAndWait() async {
    // A refresh in flight may already be past its listing call: wait for one more after it.
    let target = listGeneration + (isRefreshing ? 2 : 1)
    while listGeneration < target, !Task.isCancelled {
      if isRefreshing {
        try? await Task.sleep(for: .milliseconds(50))
      } else {
        await refresh()
      }
    }
  }

  private func applyListing(_ listing: [VMListing], configs newConfigs: [String: VMConfigFile]) {
    let newVMs = listing.filter { $0.source == .local }
    let changes = Self.stateChanges(from: vms, to: newVMs)

    if vms != newVMs { vms = newVMs }
    let newImages = listing.filter { $0.source == .oci }
    if images != newImages { images = newImages }
    if configs != newConfigs { configs = newConfigs }
    for change in changes where change.newState?.isRunning != true {
      vncURLs[change.name] = nil
      adoptedLaunches.remove(change.name)
    }
    for change in changes where change.newState?.isRunning == true && launched[change.name] == nil {
      if let pid = pid(of: change.name), Self.logRecordsLaunch(of: pid, in: logFile(for: change.name)) {
        adoptedLaunches.insert(change.name)
      }
    }
    if !changes.isEmpty {
      for observer in onChange { observer(changes) }
    }
  }

  private func installWatcher() {
    let directory = context.paths.vms
    watcher = DirectoryWatcher(url: directory) { [weak self] in
      self?.refreshSoon(after: .milliseconds(300))
    }
  }

  // MARK: Running

  /// Starts a VM with its saved run profile; `adjust` tweaks the options for this launch only
  /// (e.g. headless, VNC or recovery from the Start menu).
  func start(_ name: String, adjusting adjust: ((inout RunOptions) -> Void)? = nil) {
    var options = profiles.profile(for: name).options
    adjust?(&options)
    start(name, options: options)
  }

  /// Starts a VM with explicit options (the Run Options sheet). Applies the clipboard engine:
  /// `clipboardEngine` overrides the saved profile's engine for this launch only.
  func start(_ name: String, options requested: RunOptions, clipboardEngine: ClipboardEngine? = nil) {
    guard let client = context.client else { return }
    if isRunning(name) {
      showWindow(name)
      return
    }
    let os = os(of: name)
    if os == .macOS {
      let runningMacs = runningVMs.filter { $0.name != name && self.os(of: $0.name) == .macOS }.count
      if runningMacs >= VirtualizationLimits.maximumConcurrentMacOSGuests {
        navigation.show(
          title: "Can't start “\(name)”",
          message: "macOS allows at most two macOS virtual machines to run at the same time. Stop one of them first.")
        return
      }
    }

    var options = requested
    options.name = name
    // Values tart's argument syntax can't carry are left out of argv; never launch without them.
    guard options.isLaunchable else {
      navigation.show(
        title: "Can't start “\(name)”",
        message: options.validationProblems.joined(separator: "\n") + "\n\nFix them in Run Options.")
      return
    }
    let engine = (clipboardEngine ?? profiles.profile(for: name).clipboardEngine).resolved(for: os)
    if engine == .bridge || engine == .off { options.noClipboard = true }

    let logFile = logFile(for: name)
    let logOffset = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? UInt64) ?? 0
    do {
      let process = try client.launch(options, logFile: logFile)
      launched[name] = process
      launchedOptions[name] = options
      vncURLs[name] = nil
      watch(process, options: options, logOffset: logOffset)
      refreshSoon(after: .milliseconds(700))
    } catch {
      navigation.show(error: error, title: "Couldn't start “\(name)”")
    }
  }

  private func watch(_ process: RunningVMProcess, options: RunOptions, logOffset: UInt64) {
    let name = process.vmName
    if options.display == .vnc || options.display == .vncExperimental {
      Task { [weak self] in
        for _ in 0..<90 {
          try? await Task.sleep(for: .seconds(1))
          guard let self, process.isRunning else { return }
          if let url = Self.vncURL(in: process.logFile, from: logOffset) {
            self.vncURLs[name] = url
            return
          }
        }
      }
    }
    Task { [weak self] in
      let code = await process.waitForExit()
      guard let self else { return }
      if self.launched[name] === process {
        self.launched[name] = nil
        self.launchedOptions[name] = nil
      }
      await self.refresh()
      let normal: Set<Int32> = [0, 128 + SIGINT, 128 + SIGTERM, 128 + SIGKILL]
      if !normal.contains(code) {
        let tail = Self.logTail(process.logFile, from: logOffset, lines: 10)
        self.navigation.show(
          title: "“\(name)” stopped unexpectedly",
          message: tail.isEmpty ? "Tart exited with code \(code)." : "Tart exited with code \(code):\n\n\(tail)")
      }
    }
  }

  /// Asks the guest OS to shut down cleanly (SIGUSR2 to `tart run`; the guest may show a dialog).
  func requestShutdown(_ name: String) {
    guard let client = context.client else { return }
    do {
      try client.send(.requestGuestShutdown, toVM: name)
      refreshSoon(after: .seconds(2))
    } catch {
      navigation.show(error: error, title: "Couldn't shut down “\(name)”")
    }
  }

  /// `tart stop`: powers the VM off after the profile's timeout. On a suspended VM this discards
  /// the snapshot (callers should confirm first).
  func stop(_ name: String, timeout: Int? = nil) {
    let seconds = timeout ?? profiles.profile(for: name).stopTimeout
    jobs.run(.stop(name: name, timeoutSeconds: seconds)) { [weak self] job in
      self?.refreshSoon()
      // A VM that already stopped on its own is what the user wanted; don't report it.
      if case .failed(let message) = job.state, !message.contains("is not running") {
        self?.navigation.show(title: "Couldn't stop “\(name)”", message: message)
      }
    }
  }

  /// Kills the `tart run` process immediately (SIGKILL). Unsaved guest data is lost.
  func forceStop(_ name: String) {
    guard let pid = pid(of: name) else { return }
    if kill(pid, SIGKILL) != 0 {
      navigation.show(title: "Couldn't force “\(name)” to stop", message: String(cString: strerror(errno)))
    }
    refreshSoon(after: .milliseconds(500))
  }

  /// `tart suspend` (macOS guests started with `--suspendable`).
  func suspend(_ name: String) {
    guard canSuspend(name) else {
      navigation.show(
        title: "“\(name)” can't be suspended",
        message: "Only macOS VMs started with “Suspendable” enabled can be suspended; Tart would otherwise stop the VM. Turn it on in Run Options and restart the VM.")
      return
    }
    jobs.run(.suspend(name: name)) { [weak self] job in
      self?.refreshSoon(after: .seconds(1))
      if case .failed(let message) = job.state {
        self?.navigation.show(title: "Couldn't suspend “\(name)”", message: message)
      }
    }
  }

  /// Brings Tart's VM window to the front, or opens Screen Sharing for VNC sessions.
  func showWindow(_ name: String) {
    if let pid = pid(of: name), let app = NSRunningApplication(processIdentifier: pid), app.activate() {
      return
    }
    if let url = vncURLs[name] {
      NSWorkspace.shared.open(url)
      return
    }
    navigation.show(
      title: "“\(name)” has no window",
      message: "The VM is running without a display. Use Terminal, SSH or Screen Sharing to reach it.")
  }

  // MARK: Access

  /// Opens an interactive shell in Terminal (`tart exec -i -t <vm> <shell>`; needs the guest agent).
  func openTerminal(_ name: String) {
    let shell = os(of: name) == .linux ? "bash -l" : "zsh -l"
    let commandLine = "\(context.quotedExecutable) exec -i -t \(ShellQuoting.quote(name)) \(shell)"
    do {
      try TerminalLauncher.open(commandLine: commandLine, title: name)
    } catch {
      navigation.show(error: error, title: "Couldn't open Terminal")
    }
  }

  /// Resolves the VM's IP and opens `ssh <user>@<ip>` in Terminal.
  func openSSH(_ name: String) async {
    do {
      let address = try await resolveIP(name)
      // Local VMs reuse DHCP addresses, so a pinned host key would routinely be "wrong".
      let commandLine =
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        + ShellQuoting.quote("\(settings.sshUsername)@\(address)")
      try TerminalLauncher.open(commandLine: commandLine, title: "\(name) — SSH")
    } catch {
      navigation.show(error: error, title: "Couldn't connect to “\(name)”")
    }
  }

  /// `tart ip` with the profile's resolver.
  @discardableResult
  func resolveIP(_ name: String, resolver: IPOptions.Resolver? = nil, waitSeconds: Int = 5) async throws -> String {
    guard let client = context.client else { throw JobError.failed("Tart isn't available.") }
    let chosen = resolver ?? profiles.profile(for: name).ipResolver
    let address = try await client.ipAddress(IPOptions(name: name, waitSeconds: waitSeconds, resolver: chosen))
    ipAddresses[name] = address
    return address
  }

  func copyIP(_ name: String) async {
    do {
      let address = try await resolveIP(name)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(address, forType: .string)
    } catch {
      navigation.show(error: error, title: "Couldn't get the IP address of “\(name)”")
    }
  }

  func revealInFinder(_ name: String) {
    NSWorkspace.shared.activateFileViewerSelecting([context.paths.vmDirectory(name)])
  }

  func revealLog(_ name: String) {
    let file = logFile(for: name)
    if FileManager.default.fileExists(atPath: file.path) {
      NSWorkspace.shared.activateFileViewerSelecting([file])
    } else {
      NSWorkspace.shared.open(file.deletingLastPathComponent())
    }
  }

  // MARK: Mutations (used by sheets)

  /// Runs a command as a job, waits for it and refreshes. Throws with Tart's message on failure.
  func perform(_ command: TartCommand, standardInput: Data? = nil, title: String? = nil) async throws {
    defer { refreshSoon() }
    try await jobs.runAndWait(command, standardInput: standardInput, title: title)
  }

  /// Starts a long-running command (pull, clone, create, push, import, export) and returns at once.
  /// `onSuccess` runs on the main actor after it finished successfully; failures raise an alert.
  @discardableResult
  func performInBackground(_ command: TartCommand, title: String? = nil, onSuccess: (() -> Void)? = nil) -> Job {
    jobs.run(command, title: title) { [weak self] job in
      self?.refreshSoon()
      switch job.state {
      case .succeeded: onSuccess?()
      case .failed(let message): self?.navigation.show(title: "\(job.title) failed", message: message)
      case .cancelled, .running: break
      }
    }
  }

  /// `tart rename`; keeps the run profile and selection.
  func rename(_ name: String, to newName: String) async throws {
    try await perform(.rename(name: name, newName: newName))
    profiles.rename(from: name, to: newName)
    if navigation.selection == .vm(name) { navigation.selection = .vm(newName) }
  }

  /// `tart delete`; refuses running VMs up front with a clear message.
  func delete(_ names: [String]) async throws {
    let running = names.filter(isRunning)
    guard running.isEmpty else {
      throw JobError.failed("Stop \(running.map { "“\($0)”" }.joined(separator: ", ")) before deleting.")
    }
    try await perform(.delete(names: names))
    for name in names {
      profiles.remove(name)
      if navigation.selection == .vm(name) { navigation.selection = .dashboard }
    }
  }

  /// `tart set`; refreshes the cached configuration afterwards.
  func applySettings(_ options: SetOptions) async throws {
    try await perform(.set(options))
    if let config = try? context.client?.configuration(of: options.name) {
      configs[options.name] = config
    }
  }

  /// Whether a running VM was started by Tartelette — in this session or an earlier one.
  func wasStartedByTartelette(_ name: String) -> Bool {
    launched[name] != nil || adoptedLaunches.contains(name)
  }

  /// State transitions between two listings of local VMs: appeared (old state nil), changed, and
  /// disappeared (new state nil), sorted by name. Unchanged VMs produce nothing.
  nonisolated static func stateChanges(from old: [VMListing], to new: [VMListing]) -> [VMStateChange] {
    let oldStates = Dictionary(old.map { ($0.name, $0.state) }, uniquingKeysWith: { first, _ in first })
    let newStates = Dictionary(new.map { ($0.name, $0.state) }, uniquingKeysWith: { first, _ in first })
    var changes: [VMStateChange] = []
    for (name, state) in newStates where oldStates[name] != state {
      changes.append(VMStateChange(name: name, oldState: oldStates[name], newState: state))
    }
    for (name, state) in oldStates where newStates[name] == nil {
      changes.append(VMStateChange(name: name, oldState: state, newState: nil))
    }
    return changes.sorted { $0.name < $1.name }
  }

  // MARK: Log helpers

  /// True when the run log's latest launch header was written when process `pid` started, i.e. the
  /// VM was launched by Tartelette (possibly before the app was last quit).
  nonisolated static func logRecordsLaunch(of pid: Int32, in file: URL) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    let header = logTail(file, lines: 400)
      .split(whereSeparator: \.isNewline)
      .last { $0.hasPrefix("=== ") }
    guard let header, let end = header.range(of: " — ") else { return false }
    let stamp = header[header.index(header.startIndex, offsetBy: 4)..<end.lowerBound]
    guard let written = ISO8601DateFormatter().date(from: String(stamp)) else { return false }
    return abs(written.timeIntervalSince(started)) < 15
  }

  nonisolated static func logTail(_ file: URL, from offset: UInt64 = 0, lines: Int) -> String {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = max(offset, size > 16_384 ? size - 16_384 : 0)
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
  }

  nonisolated static func vncURL(in file: URL, from offset: UInt64) -> URL? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: offset)
    let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    return text.split(whereSeparator: \.isNewline).lazy.compactMap { TartOutputParsing.parseVNCURL(String($0)) }.first
  }
}

/// Calls `handler` on the main actor whenever entries are added, removed or renamed in a directory.
final class DirectoryWatcher {
  private let source: (any DispatchSourceFileSystemObject)?

  init?(url: URL, handler: @escaping @MainActor () -> Void) {
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated { handler() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
  }

  deinit {
    source?.cancel()
  }
}
