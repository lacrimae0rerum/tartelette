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
}
