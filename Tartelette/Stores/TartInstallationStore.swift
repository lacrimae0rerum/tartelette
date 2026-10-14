import Foundation
import Observation
import TarteletteInstall
import TarteletteKit

/// The installer operations `TartInstallationStore` uses: `ManagedTartInstaller` in the app, a fake in tests.
@MainActor
protocol ManagedTartInstalling {
  /// The installed versions, the active one and the one `rollback()` would select. Reads the disk only.
  func state() -> ManagedTartState
  /// Downloads, verifies and selects `release`. Nothing changes on failure.
  func install(_ release: TartRelease, progress: @escaping @Sendable (TartInstallProgress) -> Void) async throws
    -> ManagedTartState
  /// Selects the version that was active before the current one.
  func rollback() async throws -> ManagedTartState
  /// Deletes every managed version.
  func remove() async throws
}

extension ManagedTartInstaller: ManagedTartInstalling {}

/// The Tart Tartelette uses right now, as detected.
nonisolated struct ActiveTart: Equatable {
  enum Source: Equatable {
    /// The copy Tartelette downloaded and manages.
    case managed
    /// Homebrew's `tart` formula.
    case homebrew
    /// Anything else: `/Applications/tart.app`, a manual install, a local build.
    case other
  }

  var source: Source
  /// nil while `tart --version` hasn't answered, or when it isn't a release number (a local
  /// `SNAPSHOT` build).
  var version: TartVersion?
  /// Whether the executable is the one chosen in Settings rather than found automatically.
  var chosenInSettings: Bool

  /// The Tart `environment` describes; `versionText` is what `tart --version` printed. nil when no
  /// Tart was found.
  init?(environment: TartEnvironment?, versionText: String?) {
    guard let environment else { return nil }
    let source: Source
    var folderVersion: String?
    switch environment.source {
    case .managed(let version):
      source = .managed
      folderVersion = version
    case .homebrew:
      source = .homebrew
    case .other:
      source = .other
    }
    // A managed copy's folder names its version before `tart --version` answers.
    self.init(
      source: source, version: versionText.flatMap(TartVersion.init) ?? folderVersion.flatMap(TartVersion.init),
      chosenInSettings: environment.usesPreferredExecutable)
  }

  init(source: Source, version: TartVersion?, chosenInSettings: Bool) {
    self.source = source
    self.version = version
    self.chosenInSettings = chosenInSettings
  }
}

/// What the user should do to get the latest Tart, which depends on where the active one comes from.
nonisolated enum TartUpdateAction: Equatable {
  /// The managed copy is in use: `installLatest()` updates it with one click.
  case updateManagedCopy
  /// Homebrew's Tart is in use: run `command` in Terminal, or `installLatest()` to switch to the
  /// managed copy.
  case upgradeWithHomebrew(command: String)
  /// Another Tart, or none, is in use: `installLatest()` installs the managed copy and switches to it.
  case installManagedCopy
}

/// What the last "Check for Updates" found, judged against the Tart in use now.
nonisolated enum TartUpdateStatus: Equatable {
  /// Nothing was checked since the app started.
  case idle
  case checking
  /// The active Tart is the latest release, or newer.
  case upToDate(latest: TartRelease)
  /// `latest` is newer than the active Tart (or there's no Tart, or its version is unknown).
  case updateAvailable(latest: TartRelease, action: TartUpdateAction)
  /// The check failed; `message` says what to do.
  case failed(message: String)
}

/// The step of an installation, for a progress bar.
nonisolated enum TartInstallPhase: Equatable {
  /// Asking GitHub for the latest release.
  case findingRelease
  case downloading
  /// Checking the checksum and the signature.
  case verifying
  /// Moving the verified version into place and selecting it.
  case installing
}

/// How much of a release archive has arrived.
nonisolated struct TartDownloadAmount: Equatable {
  var received: Int64
  /// The archive's size as the release announces it.
  var expected: Int64
}

/// The operation changing the managed copy right now.
nonisolated enum TartInstallationOperation: Equatable {
  /// `version` is nil until the release is known; `fraction` (0…1) is nil while it can't be measured.
  case installing(version: TartVersion?, phase: TartInstallPhase, fraction: Double?)
  case rollingBack
  case removing
}

/// The Tart Tartelette uses, the copy it manages, and the user's manual update checks.
///
/// Nothing here connects to the network on its own: only `checkForUpdates()` and `installLatest()`
/// do, when the user asks. One operation runs at a time; while one runs (or a check), the other
/// actions are ignored.
@Observable
@MainActor
final class TartInstallationStore {
  /// How long a release found by a check is installed as is, without asking GitHub again.
  static let releaseLifetime: TimeInterval = 60 * 60

  /// The managed copy: its active, previous and installed versions.
  private(set) var managed = ManagedTartState()
  /// The install, rollback or removal running now.
  private(set) var operation: TartInstallationOperation?
  /// How much of the archive the running install downloaded, while it downloads an archive of known
  /// size.
  private(set) var downloaded: TartDownloadAmount?
  /// Why the last install, rollback or removal failed; cleared when the next one starts.
  private(set) var operationError: String?
  /// What the last check, or the lookup of the last install, found.
  private var check = Check.idle

  /// Called after an install, rollback or removal succeeded, so the app re-detects Tart (the MCP
  /// helper follows through the shared settings and detection). Running VMs are untouched.
  @ObservationIgnored var onTartChange: () -> Void = {}

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let releaseFeed: any TartReleaseFeed
  @ObservationIgnored private let installer: any ManagedTartInstalling
  @ObservationIgnored private let activeTartProvider: () -> ActiveTart?
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var installTask: Task<Void, Never>?
  /// The running install, so progress reported after it ended is dropped.
  @ObservationIgnored private var installID: UUID?

  private enum Check {
    case idle
    case checking
    case found(TartRelease, at: Date)
    case failed(message: String)
  }

  /// - Parameters:
  ///   - activeTart: The Tart detected now (from `TartContext`).
  ///   - now: The clock that dates checks, so tests can age them.
  init(
    settings: AppSettings, releaseFeed: any TartReleaseFeed, installer: any ManagedTartInstalling,
    activeTart: @escaping () -> ActiveTart?, now: @escaping () -> Date = Date.init
  ) {
    self.settings = settings
    self.releaseFeed = releaseFeed
    self.installer = installer
    self.activeTartProvider = activeTart
    self.now = now
    refresh()
  }

  /// The Tart in use now; nil when none was found.
  var activeTart: ActiveTart? { activeTartProvider() }

  /// The last check's result, judged against the Tart in use now: it follows installs, rollbacks
  /// and a Tart chosen in Settings without checking again.
  var updateStatus: TartUpdateStatus {
    switch check {
    case .idle:
      return .idle
    case .checking:
      return .checking
    case .failed(let message):
      return .failed(message: message)
    case .found(let latest, _):
      let active = activeTart
      if let version = active?.version, version >= latest.version { return .upToDate(latest: latest) }
      return .updateAvailable(latest: latest, action: Self.action(for: active?.source))
    }
  }

  /// What to do about a newer release, given where the active Tart comes from (nil: no Tart).
  static func action(for source: ActiveTart.Source?) -> TartUpdateAction {
    switch source {
    case .managed: .updateManagedCopy
    case .homebrew: .upgradeWithHomebrew(command: Links.homebrewUpgradeCommand)
    case .other, nil: .installManagedCopy
    }
  }

  /// Whether an operation or a check is running, so actions are ignored.
  var isBusy: Bool {
    if case .checking = check { return true }
    return operation != nil
  }

  /// Re-reads the managed copy from disk. Never connects to the network.
  func refresh() {
    managed = installer.state()
  }

  // MARK: Checking

  /// Asks GitHub for the latest Tart release. Ignored while busy.
  @discardableResult
  func checkForUpdates() -> Task<Void, Never>? {
    guard !isBusy else { return nil }
    check = .checking
    return Task {
      do {
        let latest = try await releaseFeed.latestRelease()
        check = .found(latest, at: now())
      } catch {
        check = .failed(message: error.localizedDescription)
      }
    }
  }

  /// The release the last check found, while it is recent enough to install without asking again.
  private var recentRelease: TartRelease? {
    guard case .found(let release, let foundAt) = check, now().timeIntervalSince(foundAt) < Self.releaseLifetime
    else { return nil }
    return release
  }

  // MARK: Operations

  /// Installs the latest release as the managed copy and makes it the Tart Tartelette uses: a Tart
  /// chosen in Settings goes back to Automatic, where the managed copy comes first.
  ///
  /// Installs the release the last check found when it is recent, so the user gets the version they
  /// were shown; otherwise asks GitHub first. Ignored while busy; `cancel()` stops it.
  @discardableResult
  func installLatest() -> Task<Void, Never>? {
    let known = recentRelease
    guard
      begin(
        .installing(
          version: known?.version, phase: known == nil ? .findingRelease : .downloading,
          fraction: known == nil ? nil : 0))
    else { return nil }
    let id = UUID()
    installID = id
    let task = Task { await install(known, id: id) }
    installTask = task
    return task
  }

  private func install(_ known: TartRelease?, id: UUID) async {
    defer {
      operation = nil
      downloaded = nil
      installID = nil
      installTask = nil
    }
    do {
      let release: TartRelease
      if let known {
        release = known
      } else {
        release = try await releaseFeed.latestRelease()
        try Task.checkCancellation()
        check = .found(release, at: now())
        operation = .installing(version: release.version, phase: .downloading, fraction: 0)
      }
      managed = try await installer.install(release) { progress in
        Task { @MainActor in self.show(progress, of: release.version, id: id) }
      }
      if settings.tartExecutablePath != nil { settings.tartExecutablePath = nil }
      onTartChange()
    } catch {
      // A cancelled request can surface as a network error; either way nothing was installed.
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      operationError = error.localizedDescription
    }
  }

  private func show(_ progress: TartInstallProgress, of version: TartVersion, id: UUID) {
    guard installID == id, case .installing = operation else { return }
    switch progress.phase {
    case .downloading:
      let fraction =
        progress.bytesExpected > 0
        ? min(1, max(0, Double(progress.bytesReceived) / Double(progress.bytesExpected))) : nil
      operation = .installing(version: version, phase: .downloading, fraction: fraction)
      downloaded =
        progress.bytesExpected > 0
        ? TartDownloadAmount(received: progress.bytesReceived, expected: progress.bytesExpected) : nil
    case .verifying:
      operation = .installing(version: version, phase: .verifying, fraction: nil)
      downloaded = nil
    case .installing:
      operation = .installing(version: version, phase: .installing, fraction: nil)
      downloaded = nil
    }
  }

  /// Goes back to the managed version that was active before. Ignored while busy.
  @discardableResult
  func rollback() -> Task<Void, Never>? {
    guard begin(.rollingBack) else { return nil }
    return Task {
      defer { operation = nil }
      do {
        managed = try await installer.rollback()
        onTartChange()
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  /// Deletes the managed copy; Tartelette then uses another Tart if there is one. Ignored while busy.
  @discardableResult
  func removeManagedCopy() -> Task<Void, Never>? {
    guard begin(.removing) else { return nil }
    return Task {
      defer { operation = nil }
      do {
        try await installer.remove()
        managed = installer.state()
        onTartChange()
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  /// Stops a running install; nothing is installed.
  func cancel() {
    installTask?.cancel()
  }

  /// Starts `operation` and clears the last error, unless something is running.
  private func begin(_ operation: TartInstallationOperation) -> Bool {
    guard !isBusy else { return false }
    operationError = nil
    self.operation = operation
    return true
  }
}
