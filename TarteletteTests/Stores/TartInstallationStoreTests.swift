import Foundation
import Testing
import TarteletteInstall
import TarteletteKit

@testable import Tartelette

/// The managed Tart as the app sees it, with a fake release feed and installer: nothing here
/// touches the network, the real Application Support folder or the app's preferences.
@Suite("Tart installation store")
final class TartInstallationStoreTests {
  private var suites: [String] = []
  private let root: URL
  private let settings: AppSettings
  private var feed = FakeReleaseFeed(.success(release("2.41.0")))
  private let installer = FakeInstaller()
  /// The Tart the store sees as detected.
  private var active: ActiveTart?
  private var now = Date(timeIntervalSince1970: 1_800_000_000)
  /// How many times the store asked the app to re-detect Tart.
  private var reloads = 0

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tartelette-installation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "tartelette-tests-\(UUID())"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    settings = AppSettings(defaults: defaults, secrets: MemorySecretStore())
  }

  isolated deinit {
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    try? FileManager.default.removeItem(at: root)
  }

  private func makeStore() -> TartInstallationStore {
    let store = TartInstallationStore(
      settings: settings, releaseFeed: feed, installer: installer, activeTart: { [weak self] in self?.active },
      now: { [weak self] in self?.now ?? .distantFuture })
    store.onTartChange = { [weak self] in self?.reloads += 1 }
    return store
  }

  // MARK: The active Tart

  @Test func theActiveTartIsTheDetectedOne() {
    func environment(_ source: TartEnvironment.Source, chosen: Bool = false) -> TartEnvironment {
      TartEnvironment(
        executable: URL(fileURLWithPath: "/opt/homebrew/bin/tart"), source: source, usesPreferredExecutable: chosen)
    }

    #expect(ActiveTart(environment: nil, versionText: nil) == nil)
    // A managed copy names its version before `tart --version` answers.
    #expect(
      ActiveTart(environment: environment(.managed(version: "2.41.0")), versionText: nil)
        == ActiveTart(source: .managed, version: TartVersion(major: 2, minor: 41), chosenInSettings: false))
    #expect(
      ActiveTart(environment: environment(.homebrew, chosen: true), versionText: "2.40.1\n")
        == ActiveTart(source: .homebrew, version: TartVersion(major: 2, minor: 40, patch: 1), chosenInSettings: true))
    #expect(
      ActiveTart(environment: environment(.other), versionText: "SNAPSHOT")
        == ActiveTart(source: .other, version: nil, chosenInSettings: false))
  }

  // MARK: Checking for updates

  @Test(arguments: [
    (ActiveTart.Source?.some(.managed), TartUpdateAction.updateManagedCopy),
    (.homebrew, .upgradeWithHomebrew(command: "brew upgrade openai/tools/tart")),
    (.other, .installManagedCopy),
    (nil, .installManagedCopy),
  ])
  func whatToDoDependsOnWhereTheActiveTartComesFrom(source: ActiveTart.Source?, action: TartUpdateAction) async {
    active = source.map { ActiveTart(source: $0, version: TartVersion("2.40.1"), chosenInSettings: false) }
    let store = makeStore()
    #expect(store.updateStatus == .idle)

    await store.checkForUpdates()?.value

    #expect(store.updateStatus == .updateAvailable(latest: release("2.41.0"), action: action))
  }

  @Test(arguments: [
    (ActiveTart(source: .managed, version: TartVersion("2.41.0"), chosenInSettings: false),
     TartUpdateStatus.upToDate(latest: release("2.41.0"))),
    // A Homebrew Tart newer than the latest GitHub release.
    (ActiveTart(source: .homebrew, version: TartVersion("2.42.0"), chosenInSettings: false),
     .upToDate(latest: release("2.41.0"))),
    (ActiveTart(source: .homebrew, version: TartVersion("2.40.1"), chosenInSettings: false),
     .updateAvailable(
       latest: release("2.41.0"), action: .upgradeWithHomebrew(command: "brew upgrade openai/tools/tart"))),
    // A local build whose version isn't a release number.
    (ActiveTart(source: .other, version: nil, chosenInSettings: true),
     .updateAvailable(latest: release("2.41.0"), action: .installManagedCopy)),
  ])
  func upToDateOnlyWhenTheActiveTartIsTheLatestOrNewer(active: ActiveTart, status: TartUpdateStatus) async {
    self.active = active
    let store = makeStore()

    await store.checkForUpdates()?.value

    #expect(store.updateStatus == status)
  }

  @Test func theResultFollowsTheTartInUse() async {
    active = ActiveTart(source: .homebrew, version: TartVersion("2.40.1"), chosenInSettings: false)
    let store = makeStore()
    await store.checkForUpdates()?.value

    active = ActiveTart(source: .managed, version: TartVersion("2.41.0"), chosenInSettings: false)

    #expect(store.updateStatus == .upToDate(latest: release("2.41.0")))
  }

  @Test func aFailedCheckSaysWhatToDo() async {
    feed = FakeReleaseFeed(.failure(FakeError("GitHub can't be reached. Try again later.")))
    let store = makeStore()

    await store.checkForUpdates()?.value

    #expect(store.updateStatus == .failed(message: "GitHub can't be reached. Try again later."))
    #expect(store.operationError == nil)
  }

  // MARK: Manual network access only

  @Test func creatingRefreshingRollingBackAndRemovingNeverConnect() async {
    installer.current = ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"])

    let store = makeStore()
    #expect(store.managed == ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"]))
    store.refresh()
    await store.rollback()?.value
    await store.removeManagedCopy()?.value

    #expect(installer.rollbacks == 1)
    #expect(installer.removals == 1)
    #expect(await feed.calls == 0)
    // Downloads only happen inside `install`.
    #expect(installer.installed.isEmpty)
  }

  @Test func refreshRereadsTheManagedCopy() {
    let store = makeStore()
    #expect(store.managed == ManagedTartState())

    installer.current = ManagedTartState(current: "2.41.0", installed: ["2.41.0"])
    store.refresh()

    #expect(store.managed == ManagedTartState(current: "2.41.0", installed: ["2.41.0"]))
  }

  // MARK: Installing

  @Test func installLatestInstallsTheReleaseTheCheckFound() async {
    active = ActiveTart(source: .managed, version: TartVersion("2.40.1"), chosenInSettings: false)
    let store = makeStore()
    await store.checkForUpdates()?.value
    // GitHub moved on, but the user clicked to install what the check showed.
    await feed.answer(with: .success(release("2.42.0")))
    now += 10 * 60

    await store.installLatest()?.value

    #expect(installer.installed == [release("2.41.0")])
    #expect(await feed.calls == 1)
  }

  @Test func installLatestLooksUpTheReleaseWithoutARecentCheck() async {
    let store = makeStore()

    // From onboarding: nothing was checked.
    await store.installLatest()?.value
    #expect(installer.installed == [release("2.41.0")])
    #expect(await feed.calls == 1)

    await feed.answer(with: .success(release("2.42.0")))
    now += 2 * 60 * 60
    await store.installLatest()?.value
    #expect(installer.installed == [release("2.41.0"), release("2.42.0")])
    #expect(await feed.calls == 2)
  }

  @Test func installingSwitchesToTheManagedCopy() async {
    settings.tartExecutablePath = "/opt/homebrew/bin/tart"
    active = ActiveTart(source: .homebrew, version: TartVersion("2.40.1"), chosenInSettings: true)
    let store = makeStore()

    await store.installLatest()?.value

    #expect(settings.tartExecutablePath == nil)
    #expect(reloads == 1)
    #expect(store.managed == ManagedTartState(current: "2.41.0", installed: ["2.41.0"]))
    #expect(store.operation == nil)
    #expect(store.operationError == nil)
  }

  @Test func rollingBackAndRemovingReloadTheTart() async {
    installer.current = ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"])
    let store = makeStore()

    await store.rollback()?.value
    #expect(store.managed == ManagedTartState(current: "2.40.1", previous: "2.41.0", installed: ["2.40.1", "2.41.0"]))
    #expect(reloads == 1)

    await store.removeManagedCopy()?.value
    #expect(store.managed == ManagedTartState())
    #expect(reloads == 2)
  }

  @Test func theInstallReportsItsPhaseAndProgress() async throws {
    let downloading = Gate()
    let verifying = Gate()
    installer.steps = [
      (TartInstallProgress(phase: .downloading, bytesReceived: 25, bytesExpected: 100), downloading),
      (TartInstallProgress(phase: .verifying, bytesReceived: 100, bytesExpected: 100), verifying),
    ]
    let store = makeStore()
    #expect(store.operation == nil)

    let install = try #require(store.installLatest())
    #expect(store.operation == .installing(version: nil, phase: .findingRelease, fraction: nil))
    let version = TartVersion("2.41.0")
    #expect(await until { store.operation == .installing(version: version, phase: .downloading, fraction: 0.25) })
    downloading.open()
    #expect(await until { store.operation == .installing(version: version, phase: .verifying, fraction: nil) })
    verifying.open()
    await install.value

    #expect(store.operation == nil)
  }

  @Test func rollingBackAndRemovingShowWhileTheyRun() async throws {
    installer.current = ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"])
    let store = makeStore()

    let rollbackGate = Gate()
    installer.pause = rollbackGate
    let rollback = try #require(store.rollback())
    #expect(store.operation == .rollingBack)
    rollbackGate.open()
    await rollback.value
    #expect(store.operation == nil)

    let removalGate = Gate()
    installer.pause = removalGate
    let removal = try #require(store.removeManagedCopy())
    #expect(store.operation == .removing)
    removalGate.open()
    await removal.value
    #expect(store.operation == nil)
  }

  // MARK: Failures

  @Test func aFailedInstallSaysWhyAndChangesNothing() async {
    settings.tartExecutablePath = "/opt/homebrew/bin/tart"
    installer.current = ManagedTartState(current: "2.40.1", installed: ["2.40.1"])
    installer.installError = FakeError("The download is damaged. Try again.")
    let store = makeStore()

    await store.installLatest()?.value

    #expect(store.operationError == "The download is damaged. Try again.")
    #expect(store.operation == nil)
    #expect(store.managed == ManagedTartState(current: "2.40.1", installed: ["2.40.1"]))
    #expect(settings.tartExecutablePath == "/opt/homebrew/bin/tart")
    #expect(reloads == 0)

    // The next attempt starts without the old message.
    installer.installError = nil
    await store.installLatest()?.value
    #expect(store.operationError == nil)
  }

  @Test func aFailedReleaseLookupStopsTheInstall() async {
    feed = FakeReleaseFeed(.failure(FakeError("GitHub can't be reached. Try again later.")))
    let store = makeStore()

    await store.installLatest()?.value

    #expect(store.operationError == "GitHub can't be reached. Try again later.")
    #expect(installer.installed.isEmpty)
    #expect(store.operation == nil)
    #expect(store.updateStatus == .idle)
    #expect(reloads == 0)
  }

  @Test func aFailedRollbackOrRemovalSaysWhyAndChangesNothing() async {
    let state = ManagedTartState(current: "2.41.0", previous: "2.40.1", installed: ["2.40.1", "2.41.0"])
    installer.current = state
    installer.rollbackError = FakeError("That version can't be used anymore.")
    installer.removeError = FakeError("Tart 2.41.0 is still running.")
    let store = makeStore()

    await store.rollback()?.value
    #expect(store.operationError == "That version can't be used anymore.")
    #expect(store.managed == state)

    await store.removeManagedCopy()?.value
    #expect(store.operationError == "Tart 2.41.0 is still running.")
    #expect(store.managed == state)
    #expect(store.operation == nil)
    #expect(reloads == 0)
  }

  // MARK: One operation at a time

  @Test func oneOperationAtATime() async throws {
    let gate = Gate()
    installer.steps = [(TartInstallProgress(phase: .downloading, bytesReceived: 0, bytesExpected: 100), gate)]
    let store = makeStore()

    let install = try #require(store.installLatest())
    #expect(store.isBusy)
    #expect(store.installLatest() == nil)
    #expect(store.rollback() == nil)
    #expect(store.removeManagedCopy() == nil)
    #expect(store.checkForUpdates() == nil)
    gate.open()
    await install.value

    #expect(!store.isBusy)
    #expect(installer.installed == [release("2.41.0")])
    #expect(installer.rollbacks == 0)
    #expect(installer.removals == 0)
    #expect(await feed.calls == 1)
  }

  @Test func nothingStartsWhileACheckRuns() async throws {
    let gate = Gate()
    feed = FakeReleaseFeed(.success(release("2.41.0")), gate: gate)
    let store = makeStore()

    let check = try #require(store.checkForUpdates())
    #expect(store.updateStatus == .checking)
    #expect(store.isBusy)
    #expect(store.installLatest() == nil)
    #expect(store.checkForUpdates() == nil)
    gate.open()
    await check.value

    #expect(!store.isBusy)
    #expect(installer.installed.isEmpty)
    #expect(await feed.calls == 1)
  }

  // MARK: Cancelling

  @Test func cancellingStopsTheInstall() async throws {
    settings.tartExecutablePath = "/opt/homebrew/bin/tart"
    installer.current = ManagedTartState(current: "2.40.1", installed: ["2.40.1"])
    installer.waitsUntilCancelled = true
    let store = makeStore()

    let install = try #require(store.installLatest())
    #expect(await until { self.installer.installed.count == 1 })
    store.cancel()
    await install.value

    #expect(installer.wasCancelled)
    #expect(store.operation == nil)
    #expect(store.operationError == nil)
    #expect(store.managed == ManagedTartState(current: "2.40.1", installed: ["2.40.1"]))
    #expect(settings.tartExecutablePath == "/opt/homebrew/bin/tart")
    #expect(reloads == 0)
    #expect(!store.isBusy)
  }

  @Test func cancellingStopsTheReleaseLookup() async throws {
    // URLSession reports a cancelled request as a network error, which mustn't show.
    feed = FakeReleaseFeed(.success(release("2.41.0")), waitsUntilCancelled: true)
    let store = makeStore()

    let install = try #require(store.installLatest())
    #expect(await until { await self.feed.calls == 1 })
    store.cancel()
    await install.value

    #expect(installer.installed.isEmpty)
    #expect(store.operation == nil)
    #expect(store.operationError == nil)
    #expect(store.updateStatus == .idle)
  }

  // MARK: App model

  @Test func theAppModelStillFindsTartFromItsSettings() async throws {
    let script = root.appendingPathComponent("tart")
    try "#!/bin/sh\necho 2.40.1\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    settings.tartExecutablePath = script.path

    let model = AppModel(settings: settings, releaseFeed: feed, installer: installer)

    #expect(model.context.environment?.executable.path == script.path)
    #expect(model.context.environment?.usesPreferredExecutable == true)
    #expect(
      await until(timeout: .seconds(10)) {
        model.installation.activeTart
          == ActiveTart(source: .other, version: TartVersion("2.40.1"), chosenInSettings: true)
      })
    #expect(await feed.calls == 0)
  }
}

// MARK: - Fakes

/// A release whose files are never downloaded.
nonisolated private func release(_ version: String) -> TartRelease {
  let base = URL(string: "https://github.com/openai/tart/releases/download/\(version)/")!
  return TartRelease(
    version: TartVersion(version)!, tag: version, publishedAt: nil,
    pageURL: URL(string: "https://github.com/openai/tart/releases/tag/\(version)")!,
    archive: TartReleaseAsset(name: "tart.tar.gz", downloadURL: base.appendingPathComponent("tart.tar.gz"), size: 100),
    checksums: TartReleaseAsset(
      name: "tart_\(version)_checksums.txt", downloadURL: base.appendingPathComponent("tart_\(version)_checksums.txt"),
      size: 80))
}

nonisolated private struct FakeError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Waits until opened; opening before anyone waits lets them through at once.
private final class Gate {
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    waiting.forEach { $0.resume() }
    waiting = []
  }
}

/// Counts every lookup, the only way the store reaches the network.
private actor FakeReleaseFeed: TartReleaseFeed {
  private(set) var calls = 0
  private var result: Result<TartRelease, any Error>
  private let gate: Gate?
  private let waitsUntilCancelled: Bool

  init(_ result: Result<TartRelease, any Error>, gate: Gate? = nil, waitsUntilCancelled: Bool = false) {
    self.result = result
    self.gate = gate
    self.waitsUntilCancelled = waitsUntilCancelled
  }

  func answer(with result: Result<TartRelease, any Error>) {
    self.result = result
  }

  func latestRelease() async throws -> TartRelease {
    calls += 1
    if let gate { await gate.wait() }
    if waitsUntilCancelled {
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        throw FakeError("Tartelette couldn't reach GitHub.")
      }
    }
    return try result.get()
  }
}

/// Records what the store asks of the installer; `install` adds the release and selects it.
private final class FakeInstaller: ManagedTartInstalling {
  var current = ManagedTartState()
  var installed: [TartRelease] = []
  var rollbacks = 0
  var removals = 0
  var installError: (any Error)?
  var rollbackError: (any Error)?
  var removeError: (any Error)?
  /// Progress to report while installing, each followed by a pause until its gate opens.
  var steps: [(TartInstallProgress, Gate)] = []
  /// Holds a rollback or a removal until it opens.
  var pause: Gate?
  var waitsUntilCancelled = false
  private(set) var wasCancelled = false

  func state() -> ManagedTartState { current }

  func install(_ release: TartRelease, progress: @escaping @Sendable (TartInstallProgress) -> Void) async throws
    -> ManagedTartState
  {
    installed.append(release)
    for (step, gate) in steps {
      progress(step)
      await gate.wait()
    }
    if waitsUntilCancelled {
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        wasCancelled = true
        throw CancellationError()
      }
    }
    if let installError { throw installError }
    let version = release.version.description
    current = ManagedTartState(
      current: version, previous: current.current,
      installed: current.installed.contains(version) ? current.installed : current.installed + [version])
    return current
  }

  func rollback() async throws -> ManagedTartState {
    rollbacks += 1
    if let pause { await pause.wait() }
    if let rollbackError { throw rollbackError }
    current = ManagedTartState(current: current.previous, previous: current.current, installed: current.installed)
    return current
  }

  func remove() async throws {
    removals += 1
    if let pause { await pause.wait() }
    if let removeError { throw removeError }
    current = ManagedTartState()
  }
}

/// Polls `condition` until it holds or `timeout` passes.
private func until(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}
