import Foundation
import TarteletteCore
import Testing

@testable import TarteletteAgents

@Suite("VM fingerprint")
struct VMFingerprintTests {
  @Test func sameDirectoryKeepsItsFingerprint() throws {
    let home = try TemporaryDirectory()
    defer { home.remove() }
    let paths = TartPaths(home: home.url)
    try FileManager.default.createDirectory(at: paths.vmDirectory("dev"), withIntermediateDirectories: true)

    let first = try #require(VMFingerprint.of(vmNamed: "dev", paths: paths))
    try Data("{}".utf8).write(to: paths.configFile("dev"))

    #expect(VMFingerprint.of(vmNamed: "dev", paths: paths) == first)
    #expect(VMFingerprint.of(directory: paths.vmDirectory("dev")) == first)
  }

  @Test func recreatedDirectoryGetsANewFingerprint() throws {
    let home = try TemporaryDirectory()
    defer { home.remove() }
    let paths = TartPaths(home: home.url)
    let directory = paths.vmDirectory("dev")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = try #require(VMFingerprint.of(vmNamed: "dev", paths: paths))

    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let recreated = try #require(VMFingerprint.of(vmNamed: "dev", paths: paths))
    #expect(recreated != original)
  }

  @Test func missingDirectoryHasNoFingerprint() throws {
    let home = try TemporaryDirectory()
    defer { home.remove() }
    let paths = TartPaths(home: home.url)
    #expect(VMFingerprint.of(vmNamed: "absent", paths: paths) == nil)

    // A plain file where the VM directory should be isn't a VM.
    try FileManager.default.createDirectory(at: paths.vms, withIntermediateDirectories: true)
    try Data().write(to: paths.vms.appendingPathComponent("file", isDirectory: false))
    #expect(VMFingerprint.of(vmNamed: "file", paths: paths) == nil)
  }
}
