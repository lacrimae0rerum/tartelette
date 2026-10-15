import Foundation
import Testing

@testable import TarteletteCLI

@Suite("Tart environment detection")
struct TartEnvironmentTests {
  /// A scratch managed layout plus a stand-in for another installed `tart`, removed by `remove()`.
  struct Fixture {
    let directory: URL
    let layout: ManagedTartLayout
    let otherTart: URL

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tartelette-environment-\(UUID().uuidString)", isDirectory: true)
      layout = ManagedTartLayout(root: directory.appendingPathComponent("Managed", isDirectory: true))
      otherTart = directory.appendingPathComponent("other/tart")
      try Self.makeExecutable(otherTart)
    }

    /// The managed executable as the installer lays it out, spelled independently of `layout`.
    var managedExecutable: URL { directory.appendingPathComponent("Managed/current/tart.app/Contents/MacOS/tart") }

    /// Installs a stand-in `tart.app` for `version` and selects it.
    func installManaged(_ version: String) throws {
      try Self.makeExecutable(
        directory.appendingPathComponent("Managed/versions/\(version)/tart.app/Contents/MacOS/tart"))
      try selectManaged(version)
    }

    /// Points `current` at `versions/<version>` with a relative link, installed or not.
    func selectManaged(_ version: String) throws {
      let root = directory.appendingPathComponent("Managed", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("current").path, withDestinationPath: "versions/\(version)")
    }

    func detect(preferred: String? = nil) -> TartEnvironment? {
      TartEnvironment.detect(
        preferredExecutablePath: preferred, tartHome: nil, managedLayout: layout, otherCandidates: [otherTart.path])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func makeExecutable(_ url: URL) throws {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("#!/bin/sh\n".utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
  }

  @Test func findsTheManagedCopyBeforeOtherInstalls() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.installManaged("2.41.0")

    let detected = try #require(fixture.detect())

    #expect(detected.executable.path == fixture.managedExecutable.path)
    #expect(detected.source == .managed(version: "2.41.0"))
    #expect(detected.usesPreferredExecutable == false)
    #expect(fixture.layout.currentVersion == "2.41.0")
  }

  @Test func reportsWhetherTartCameFromThePreferredPath() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let chosen = fixture.directory.appendingPathComponent("chosen/tart")
    try Fixture.makeExecutable(chosen)

    #expect(fixture.detect(preferred: chosen.path)?.usesPreferredExecutable == true)
    #expect(fixture.detect()?.usesPreferredExecutable == false)
  }

  @Test func thePreferredPathStillWinsOverEverything() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.installManaged("2.41.0")
    let chosen = fixture.directory.appendingPathComponent("chosen/tart")
    try Fixture.makeExecutable(chosen)

    #expect(fixture.detect(preferred: chosen.path)?.executable.path == chosen.path)
  }

  @Test func aNonExecutablePreferredPathStillFallsThrough() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.installManaged("2.41.0")
    let chosen = fixture.directory.appendingPathComponent("chosen/tart")
    try Fixture.makeExecutable(chosen)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chosen.path)

    let detected = try #require(fixture.detect(preferred: chosen.path))

    #expect(detected.executable.path == fixture.managedExecutable.path)
    #expect(detected.usesPreferredExecutable == false)
  }

  @Test func aManagedTartStillFindsHomebrewSoftnet() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.installManaged("2.41.0")
    let detected = try #require(
      TartEnvironment.detect(
        preferredExecutablePath: nil, tartHome: nil, managedLayout: fixture.layout, otherCandidates: []))

    // An app launched from Finder inherits a PATH without Homebrew.
    let directories = detected.searchPath(inheriting: "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")

    #expect(directories.contains("/opt/homebrew/bin"))
    #expect(directories.contains("/usr/local/bin"))
  }

  @Test func skipsAMissingOrDanglingCurrentLink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(fixture.layout.currentVersion == nil)
    #expect(fixture.detect()?.executable.path == fixture.otherTart.path)

    try fixture.selectManaged("2.40.1")

    #expect(fixture.layout.currentVersion == nil)
    let detected = try #require(fixture.detect())
    #expect(detected.executable.path == fixture.otherTart.path)
    #expect(detected.source == .other)
  }

  @Test func classifiesWhereTartComesFrom() {
    let layout = ManagedTartLayout(root: URL(fileURLWithPath: "/Managed/Tart", isDirectory: true))
    func source(_ executable: String, resolved: String? = nil) -> TartEnvironment.Source {
      TartEnvironment.Source.classify(
        executable: URL(fileURLWithPath: executable),
        resolvedExecutable: URL(fileURLWithPath: resolved ?? executable),
        managedLayout: layout)
    }

    #expect(
      source(
        "/Managed/Tart/current/tart.app/Contents/MacOS/tart",
        resolved: "/Managed/Tart/versions/2.41.0/tart.app/Contents/MacOS/tart") == .managed(version: "2.41.0"))
    #expect(source("/Managed/Tart/versions/2.40.1/tart.app/Contents/MacOS/tart") == .managed(version: "2.40.1"))
    #expect(source("/opt/homebrew/bin/tart", resolved: "/opt/homebrew/Cellar/tart/2.40.1/bin/tart") == .homebrew)
    #expect(source("/opt/homebrew/Cellar/tart/2.40.1/libexec/tart.app/Contents/MacOS/tart") == .homebrew)
    #expect(source("/usr/local/bin/tart", resolved: "/usr/local/Cellar/tart/2.40.1/bin/tart") == .homebrew)
    #expect(source("/usr/local/bin/tart") == .other)
    #expect(source("/Applications/tart.app/Contents/MacOS/tart") == .other)
  }
}
