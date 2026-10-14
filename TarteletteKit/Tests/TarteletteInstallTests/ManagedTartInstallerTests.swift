import Foundation
import Testing

import TarteletteCLI
@testable import TarteletteInstall

@Suite("Installing the managed Tart")
struct ManagedTartInstallerTests {
  /// Records progress reports.
  final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TartInstallProgress] = []
    var reports: [TartInstallProgress] { lock.withLock { values } }
    func record(_ value: TartInstallProgress) { lock.withLock { values.append(value) } }
  }

  // MARK: - Installing

  @Test func installsTheVerifiedReleaseUnmodifiedAndSelectsIt() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")

    let state = try await fixture.installer.install(release)

    #expect(state == ManagedTartState(current: "2.42.0", previous: nil, installed: ["2.42.0"]))
    #expect(fixture.currentDestination == "versions/2.42.0")
    #expect(fixture.layout.currentVersion == "2.42.0")
    #expect(
      try Data(contentsOf: fixture.managed("current/tart.app/Contents/MacOS/tart"))
        == InstallerFixture.executable("2.42.0"))
    #expect(try Data(contentsOf: fixture.managed("versions/2.42.0/LICENSE")) == InstallerFixture.license)
    #expect(fixture.verifier.checkedApps.map(\.lastPathComponent) == ["tart.app"])
    #expect(fixture.stagingIsEmpty)
    #expect(fixture.installer.state() == state)
  }

  @Test func downloadsTheChecksumsAndTheArchiveWithALimitAboveTheAnnouncedSize() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")

    try await fixture.installer.install(release)

    let calls = fixture.downloader.calls
    #expect(Set(calls.map(\.url)) == [release.archive.downloadURL, release.checksums.downloadURL])
    let archiveLimit = try #require(calls.first { $0.url == release.archive.downloadURL }?.limit)
    #expect(archiveLimit > release.archive.size)
    #expect(archiveLimit <= release.archive.size * 2 + 1_048_576)
  }

  @Test func reportsDownloadingThenVerifyingThenInstalling() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    let log = ProgressLog()

    try await fixture.installer.install(release, progress: log.record)

    let reports = log.reports
    #expect(reports.allSatisfy { $0.bytesExpected == release.archive.size })
    let downloads = reports.filter { $0.phase == .downloading }
    #expect(downloads.last?.bytesReceived == release.archive.size)
    var phases: [TartInstallProgress.Phase] = []
    for report in reports where phases.last != report.phase { phases.append(report.phase) }
    #expect(phases == [.downloading, .verifying, .installing])
  }

  @Test func keepsThePreviousVersionWhenUpdating() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.41.0"))

    let state = try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(state == ManagedTartState(current: "2.42.0", previous: "2.41.0", installed: ["2.41.0", "2.42.0"]))
    #expect(fixture.currentDestination == "versions/2.42.0")
    #expect(
      try Data(contentsOf: fixture.managed("versions/2.41.0/tart.app/Contents/MacOS/tart"))
        == InstallerFixture.executable("2.41.0"))
  }

  @Test func reinstallingAnInstalledVersionSwitchesToItWithoutDownloading() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let older = try fixture.publish("2.41.0")
    try await fixture.installer.install(older)
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    let downloads = fixture.downloader.calls.count

    let state = try await fixture.installer.install(older)

    #expect(fixture.downloader.calls.count == downloads)
    #expect(state == ManagedTartState(current: "2.41.0", previous: "2.42.0", installed: ["2.41.0", "2.42.0"]))
    #expect(fixture.currentDestination == "versions/2.41.0")
  }

  @Test func reinstallingTheCurrentVersionChangesNothing() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    let release = try fixture.publish("2.42.0")
    try await fixture.installer.install(release)
    let before = LayoutSnapshot(fixture.layout.root)
    try #require(before.entries["current"] == "link → versions/2.42.0")
    let downloads = fixture.downloader.calls.count

    try await fixture.installer.install(release)

    #expect(LayoutSnapshot(fixture.layout.root) == before)
    #expect(fixture.downloader.calls.count == downloads)
  }

  @Test func cleansStagingLeftByAnEarlierCrash() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let leftover = fixture.managed("staging/crashed/tart.tar.gz")
    try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: leftover)

    try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(fixture.stagingIsEmpty)
  }

  // MARK: - Failures leave everything as it was

  /// Runs `failingOperation`, which expects its own failure, on a fixture where 2.41.0 is installed,
  /// and checks that `versions/`, `current` and the manifest are byte-identical afterwards and that
  /// staging is empty.
  func expectNothingChanges(
    _ fixture: InstallerFixture, sourceLocation: SourceLocation = #_sourceLocation,
    when failingOperation: () async throws -> Void
  ) async throws {
    let before = LayoutSnapshot(fixture.layout.root)
    #expect(before.entries["current"] == "link → versions/2.41.0", sourceLocation: sourceLocation)
    try await failingOperation()
    let after = LayoutSnapshot(fixture.layout.root)
    #expect(after == before, "the layout changed:\n\(after)", sourceLocation: sourceLocation)
    #expect(fixture.stagingIsEmpty, sourceLocation: sourceLocation)
  }

  func installedFixture() async throws -> InstallerFixture {
    let fixture = try InstallerFixture()
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    return fixture
  }

  @Test func refusesAnArchiveWhoseChecksumDiffers() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0", checksum: String(repeating: "ab", count: 32))
    let checked = fixture.verifier.checkedApps.count

    try await expectNothingChanges(fixture) {
      await #expect(throws: TartInstallError.checksumMismatch(fileName: "tart.tar.gz")) {
        try await fixture.installer.install(release)
      }
    }
    #expect(fixture.verifier.checkedApps.count == checked)
  }

  @Test func refusesAChecksumsFileThatDoesntListTheArchive() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    fixture.downloader.answer(
      release.checksums.downloadURL, with: .file(Data("\(String(repeating: "ab", count: 32))  other.tar.gz\n".utf8)))

    try await expectNothingChanges(fixture) {
      await #expect(throws: TartReleaseError.missingChecksum(fileName: "tart.tar.gz")) {
        try await fixture.installer.install(release)
      }
    }
  }

  @Test(arguments: [
    TartInstallError.network(reason: "offline"), .downloadTooLarge(fileName: "tart.tar.gz"),
    .insecureURL("http://example.com/tart.tar.gz"), .httpStatus(500), .diskFull,
  ])
  func reportsADownloadFailure(_ failure: TartInstallError) async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    fixture.downloader.answer(release.archive.downloadURL, with: .failure(failure))

    try await expectNothingChanges(fixture) {
      await #expect(throws: failure) { try await fixture.installer.install(release) }
    }
  }

  @Test func reportsAnArchiveTarCantUnpack() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0", contents: .notAnArchive)

    try await expectNothingChanges(fixture) {
      let error = await #expect(throws: TartInstallError.self) { try await fixture.installer.install(release) }
      guard case .extractionFailed = error else {
        Issue.record("Expected an extraction failure, got \(String(describing: error))")
        return
      }
    }
  }

  @Test(arguments: [ArchiveContents.appIsSymlink, .withoutLicense, .withoutApp, .withExtraEntry])
  func refusesAnArchiveWithUnexpectedContents(_ contents: ArchiveContents) async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0", contents: contents)
    let checked = fixture.verifier.checkedApps.count

    try await expectNothingChanges(fixture) {
      let error = await #expect(throws: TartInstallError.self) { try await fixture.installer.install(release) }
      guard case .unexpectedArchive = error else {
        Issue.record("Expected unexpected contents, got \(String(describing: error))")
        return
      }
    }
    #expect(fixture.verifier.checkedApps.count == checked)
  }

  @Test func refusesAnAppThatFailsTheSignatureCheck() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    let rejection = TartInstallError.signatureRejected(signer: "ad-hoc", reason: "no developer certificate")
    fixture.verifier.reject(with: rejection)

    try await expectNothingChanges(fixture) {
      await #expect(throws: rejection) { try await fixture.installer.install(release) }
    }
  }

  @Test func refusesAnAppThatClaimsAnotherVersion() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0", bundleVersion: "2.40.0")

    try await expectNothingChanges(fixture) {
      await #expect(throws: TartInstallError.versionMismatch(expected: "2.42.0", found: "2.40.0")) {
        try await fixture.installer.install(release)
      }
    }
  }

  @Test func reportsAFileSystemFailureWhenVersionsIsReadOnly() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.managed("versions").path)

    try await expectNothingChanges(fixture) {
      let error = await #expect(throws: TartInstallError.self) { try await fixture.installer.install(release) }
      guard case .fileSystem = error else {
        Issue.record("Expected a file system failure, got \(String(describing: error))")
        return
      }
    }
  }

  @Test func putsTheVersionBackWhenCurrentCantBeSwitched() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    // A folder where the link should be can't be replaced by renaming a link over it.
    try FileManager.default.removeItem(at: fixture.managed("current"))
    try FileManager.default.createDirectory(at: fixture.managed("current/keep"), withIntermediateDirectories: true)
    let before = LayoutSnapshot(fixture.layout.root)

    let error = await #expect(throws: TartInstallError.self) { try await fixture.installer.install(release) }
    guard case .fileSystem = error else {
      Issue.record("Expected a file system failure, got \(String(describing: error))")
      return
    }
    #expect(LayoutSnapshot(fixture.layout.root) == before)
    #expect(fixture.stagingIsEmpty)
  }

  @Test func cancellingLeavesNothingBehind() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    fixture.downloader.answer(release.archive.downloadURL, with: .stallUntilCancelled)
    let installer = fixture.installer

    try await expectNothingChanges(fixture) {
      let install = Task {
        defer { fixture.downloader.stalledContinuation.finish() }
        return try await installer.install(release)
      }
      for await _ in fixture.downloader.stalled { break }
      install.cancel()
      await #expect(throws: CancellationError.self) { try await install.value }
    }
  }

  @Test func refusesToStartWhileAnotherProcessHoldsTheLock() async throws {
    let fixture = try await installedFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    let descriptor = open(fixture.managed(".lock").path, O_RDWR | O_CREAT, 0o644)
    defer { close(descriptor) }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

    try await expectNothingChanges(fixture) {
      await #expect(throws: TartInstallError.busy) { try await fixture.installer.install(release) }
    }
    #expect(fixture.downloader.calls.count == 2)
  }

  @Test func reportsAFullDiskAsSuch() {
    #expect(TartInstallError.fileSystem(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
    #expect(TartInstallError.fileSystem(POSIXError(.ENOSPC)) == .diskFull)
    #expect(TartInstallError.fileSystem(CocoaError(.fileWriteNoPermission)) != .diskFull)
  }
}
