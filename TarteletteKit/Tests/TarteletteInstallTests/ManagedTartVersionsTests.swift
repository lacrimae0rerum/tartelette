import Foundation
import Testing

import TarteletteCLI
@testable import TarteletteInstall

@Suite("Managing installed Tart versions")
struct ManagedTartVersionsTests {
  // MARK: - Pruning

  @Test func keepsOnlyTheCurrentAndPreviousVersionsAfterUpdating() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    for version in ["2.40.0", "2.41.0", "2.42.0"] {
      try await fixture.installer.install(try fixture.publish(version))
    }

    #expect(fixture.installer.state().installed == ["2.41.0", "2.42.0"])
    #expect(!FileManager.default.fileExists(atPath: fixture.managed("versions/2.40.0").path))
    #expect(fixture.stagingIsEmpty)
  }

  @Test func keepsAVersionARunningProcessExecutesUntilItStops() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.40.0"))
    // The kernel reports executables with symbolic links resolved.
    fixture.running.set([fixture.realPath("versions/2.40.0/tart.app/Contents/MacOS/tart")])
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(fixture.installer.state().installed == ["2.40.0", "2.41.0", "2.42.0"])
    #expect(try await fixture.installer.prune() == [])

    fixture.running.set([])
    #expect(try await fixture.installer.prune() == ["2.40.0"])
    #expect(fixture.installer.state().installed == ["2.41.0", "2.42.0"])
  }

  @Test func switchingBackToAnInstalledVersionPrunesTheVersionsLeftUnused() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.40.0"))
    fixture.running.set([fixture.realPath("versions/2.40.0/tart.app/Contents/MacOS/tart")])
    let older = try fixture.publish("2.41.0")
    try await fixture.installer.install(older)
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    fixture.running.set([])

    let state = try await fixture.installer.install(older)

    #expect(state == ManagedTartState(current: "2.41.0", previous: "2.42.0", installed: ["2.41.0", "2.42.0"]))
  }

  @Test func rollbackAndPruneCreateNothingWhenNothingIsInstalled() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }

    await #expect(throws: TartInstallError.noPreviousVersion) { try await fixture.installer.rollback() }
    #expect(try await fixture.installer.prune() == [])
    #expect(!FileManager.default.fileExists(atPath: fixture.managed("").path))
  }

  @Test func pruningPutsEveryVersionBackWhenOneCantBeRemoved() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let older = ["2.39.0", "2.40.0"]
    fixture.running.set(older.map { fixture.realPath("versions/\($0)/tart.app/Contents/MacOS/tart") })
    for version in older + ["2.41.0", "2.42.0"] {
      try await fixture.installer.install(try fixture.publish(version))
    }
    fixture.running.set([])
    // A folder without write permission can't be moved out of `versions/`; 2.39.0 moves first.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: fixture.managed("versions/2.40.0").path)
    let before = LayoutSnapshot(fixture.layout.root)

    let error = await #expect(throws: TartInstallError.self) { try await fixture.installer.prune() }
    guard case .fileSystem = error else {
      Issue.record("Expected a file system failure, got \(String(describing: error))")
      return
    }
    #expect(LayoutSnapshot(fixture.layout.root) == before)
    #expect(fixture.installer.state().installed == ["2.39.0", "2.40.0", "2.41.0", "2.42.0"])
    #expect(fixture.stagingIsEmpty)
  }

  static let listingFailure = TartInstallError.runningProcessesUnknown(reason: "proc_listpids: not permitted")

  @Test func pruneKeepsEveryVersionWhenProcessesCantBeListed() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.40.0"))
    fixture.running.set([fixture.realPath("versions/2.40.0/tart.app/Contents/MacOS/tart")])
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    fixture.running.fail(with: Self.listingFailure)
    let before = LayoutSnapshot(fixture.layout.root)

    await #expect(throws: Self.listingFailure) { try await fixture.installer.prune() }
    #expect(LayoutSnapshot(fixture.layout.root) == before)
    #expect(fixture.installer.state().installed == ["2.40.0", "2.41.0", "2.42.0"])
  }

  @Test func installingKeepsEveryVersionWhenProcessesCantBeListed() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.40.0"))
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    fixture.running.fail(with: Self.listingFailure)

    let state = try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(
      state == ManagedTartState(current: "2.42.0", previous: "2.41.0", installed: ["2.40.0", "2.41.0", "2.42.0"]))
  }

  @Test func refusesToReplaceABrokenVersionWhenProcessesCantBeListed() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let release = try fixture.publish("2.42.0")
    try await fixture.installer.install(release)
    fixture.verifier.reject(
      appsIn: fixture.managed("versions/2.42.0"), with: .signatureRejected(signer: "ad-hoc", reason: "modified"))
    fixture.running.fail(with: Self.listingFailure)
    let before = LayoutSnapshot(fixture.layout.root)

    await #expect(throws: Self.listingFailure) { try await fixture.installer.install(release) }
    #expect(LayoutSnapshot(fixture.layout.root) == before)
  }

  // MARK: - Rolling back

  @Test func rollbackSelectsThePreviousVersionAndRemembersTheOneItLeft() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    try await fixture.installer.install(try fixture.publish("2.42.0"))

    let back = try await fixture.installer.rollback()
    #expect(back == ManagedTartState(current: "2.41.0", previous: "2.42.0", installed: ["2.41.0", "2.42.0"]))
    #expect(fixture.currentDestination == "versions/2.41.0")

    let forward = try await fixture.installer.rollback()
    #expect(forward == ManagedTartState(current: "2.42.0", previous: "2.41.0", installed: ["2.41.0", "2.42.0"]))
    #expect(fixture.currentDestination == "versions/2.42.0")
  }

  @Test func rollbackWithoutAnEarlierVersionFailsAndChangesNothing() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    let before = LayoutSnapshot(fixture.layout.root)

    await #expect(throws: TartInstallError.noPreviousVersion) { try await fixture.installer.rollback() }
    #expect(LayoutSnapshot(fixture.layout.root) == before)
  }

  // MARK: - Removing

  @Test func removeDeletesTheManagedCopy() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    try #require(fixture.installer.state().installed == ["2.41.0", "2.42.0"])

    try await fixture.installer.remove()

    #expect(!FileManager.default.fileExists(atPath: fixture.managed("").path))
    #expect(fixture.installer.state() == ManagedTartState())
    #expect(TartEnvironment.detect(managedLayout: fixture.layout)?.source != .managed(version: "2.42.0"))
  }

  @Test func removeChangesNothingWhenProcessesCantBeListed() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    fixture.running.fail(with: Self.listingFailure)
    let before = LayoutSnapshot(fixture.layout.root)

    await #expect(throws: Self.listingFailure) { try await fixture.installer.remove() }
    #expect(LayoutSnapshot(fixture.layout.root) == before)
  }

  /// Leaves a copy like the one `remove()` renames aside, holding `version`.
  func leaveRemovedCopy(_ fixture: InstallerFixture, named name: String, version: String) throws -> URL {
    let copy = fixture.scratch.appending(name)
    let macOS = copy.appendingPathComponent("versions/\(version)/tart.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try InstallerFixture.executable(version).write(to: macOS.appendingPathComponent("tart"))
    return copy
  }

  @Test func theNextOperationDeletesCopiesARemoveLeftBehindUnlessTheyRun() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let unused = try leaveRemovedCopy(fixture, named: ".Managed-removing-A", version: "2.39.0")
    let running = try leaveRemovedCopy(fixture, named: ".Managed-removing-B", version: "2.40.0")
    fixture.running.set([running.appendingPathComponent("versions/2.40.0/tart.app/Contents/MacOS/tart").path])

    try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(!FileManager.default.fileExists(atPath: unused.path))
    #expect(FileManager.default.fileExists(atPath: running.path))
  }

  @Test func removeSucceedsWhenTheCopyItSetAsideCantBeDeleted() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    // Without write permission on its folder, the executable can't be deleted.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: fixture.managed("versions/2.42.0/tart.app/Contents/MacOS").path)

    try await fixture.installer.remove()

    #expect(!FileManager.default.fileExists(atPath: fixture.managed("").path))
    #expect(fixture.installer.state() == ManagedTartState())
  }

  @Test func removeReportsACopyThatStartedRunningAndCantBeDeleted() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: fixture.managed("versions/2.42.0/tart.app/Contents/MacOS").path)
    // A process starts from the copy after `remove()` checked: it runs from wherever the copy went.
    let scratch = fixture.scratch.url
    fixture.running.set {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
      return names.filter { $0.hasPrefix(".Managed-removing-") }.map {
        scratch.appendingPathComponent("\($0)/versions/2.42.0/tart.app/Contents/MacOS/tart").path
      }
    }

    await #expect(throws: TartInstallError.inUse(versions: ["2.42.0"])) { try await fixture.installer.remove() }
  }

  @Test func removeRefusesWhileAProcessRunsAnyVersion() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    fixture.running.set([fixture.realPath("versions/2.41.0/tart.app/Contents/MacOS/tart")])
    let before = LayoutSnapshot(fixture.layout.root)

    let error = await #expect(throws: TartInstallError.self) { try await fixture.installer.remove() }
    #expect(error == .inUse(versions: ["2.41.0"]))
    #expect(error?.errorDescription?.contains("Stop those virtual machines") == true)
    #expect(LayoutSnapshot(fixture.layout.root) == before)
  }

  // MARK: - Links inside the managed folder are never followed

  /// A folder outside the managed root holding `keep.txt`, and its listing.
  func outsideFolder(_ fixture: InstallerFixture) throws -> URL {
    let outside = fixture.scratch.appending("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
    return outside
  }

  func isRealDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
  }

  @Test func cleaningStagingRemovesAStagingLinkButNeverItsTarget() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let outside = try outsideFolder(fixture)
    try FileManager.default.createDirectory(at: fixture.managed(""), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.managed("staging"), withDestinationURL: outside)

    try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    #expect(isRealDirectory(fixture.managed("staging")))
    #expect(fixture.stagingIsEmpty)
  }

  @Test func replacesAStagingFileWithAFolder() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.managed(""), withIntermediateDirectories: true)
    try Data("not a folder".utf8).write(to: fixture.managed("staging"))

    try await fixture.installer.install(try fixture.publish("2.42.0"))

    #expect(isRealDirectory(fixture.managed("staging")))
    #expect(fixture.currentDestination == "versions/2.42.0")
  }

  @Test func switchingNeverWritesThroughAStagingLink() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    try await fixture.installer.install(try fixture.publish("2.41.0"))
    try await fixture.installer.install(try fixture.publish("2.42.0"))
    let outside = try outsideFolder(fixture)
    try FileManager.default.removeItem(at: fixture.managed("staging"))
    try FileManager.default.createSymbolicLink(at: fixture.managed("staging"), withDestinationURL: outside)

    try await fixture.installer.rollback()

    #expect(fixture.currentDestination == "versions/2.41.0")
    #expect(isRealDirectory(fixture.managed("staging")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
  }

  @Test func refusesALockFileThatIsALink() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let outside = try outsideFolder(fixture)
    try FileManager.default.createDirectory(at: fixture.managed(""), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.managed(".lock"), withDestinationURL: outside.appendingPathComponent("lock"))

    let error = await #expect(throws: TartInstallError.self) {
      try await fixture.installer.install(try fixture.publish("2.42.0"))
    }
    guard case .fileSystem = error else {
      Issue.record("Expected a file system failure, got \(String(describing: error))")
      return
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    #expect(fixture.currentDestination == nil)
  }

  @Test func neverPrunesOrRemovesThroughAVersionsLink() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let outside = try outsideFolder(fixture)
    for version in ["2.40.0", "2.41.0"] {
      try FileManager.default.createDirectory(
        at: outside.appendingPathComponent("\(version)/tart.app/Contents"), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: fixture.managed(""), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.managed("versions"), withDestinationURL: outside)

    #expect(try await fixture.installer.prune() == [])
    try await fixture.installer.remove()

    let left = try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
    #expect(left == ["2.40.0", "2.41.0", "keep.txt"])
    #expect(!FileManager.default.fileExists(atPath: fixture.managed("").path))
  }
}
