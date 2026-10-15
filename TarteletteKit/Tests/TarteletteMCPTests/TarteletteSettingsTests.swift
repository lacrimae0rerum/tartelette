import Foundation
import Testing

@testable import TarteletteAgents
@testable import TarteletteCLI
@testable import TarteletteMCP

@Suite("Tartelette settings for the MCP helper")
struct TarteletteSettingsTests {
  /// A preferences domain of its own, removed afterwards.
  struct TestDefaults {
    let suite = "tartelette-mcp-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
    }

    func remove() { defaults.removePersistentDomain(forName: suite) }
  }

  @Test func readsTheAppsTartSettings() throws {
    let test = try TestDefaults()
    defer { test.remove() }
    test.defaults.set("/opt/tools/tart", forKey: "settings.tartExecutablePath")
    test.defaults.set("~/VMs", forKey: "settings.tartHome")
    test.defaults.set(true, forKey: "settings.disableAutoPrune")

    #expect(
      TarteletteSettings(defaults: test.defaults)
        == TarteletteSettings(
          tartExecutablePath: "/opt/tools/tart", tartHome: "~/VMs", tartVariables: ["TART_NO_AUTO_PRUNE": "1"]))
  }

  @Test func defaultsToAutoDetection() throws {
    let test = try TestDefaults()
    defer { test.remove() }
    test.defaults.set("", forKey: "settings.tartHome")
    test.defaults.set(false, forKey: "settings.disableAutoPrune")

    #expect(TarteletteSettings(defaults: test.defaults) == TarteletteSettings())
  }

  @Test func usesTheStandardDefaultsInsideTheApp() {
    let insideTheApp = TarteletteSettings.appDefaults(bundleIdentifier: "io.github.lacrimae0rerum.Tartelette")
    #expect(insideTheApp === UserDefaults.standard)
    #expect(TarteletteSettings.appDefaults(bundleIdentifier: "com.example.other") !== UserDefaults.standard)
  }

  @Test func buildsAToolboxForTheChosenTart() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let tart = directory.url.appendingPathComponent("tart")
    try Data("#!/bin/sh\n".utf8).write(to: tart)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tart.path)
    let home = directory.url.appendingPathComponent("home", isDirectory: true)
    let settings = TarteletteSettings(
      tartExecutablePath: tart.path, tartHome: home.path, tartVariables: ["TART_NO_AUTO_PRUNE": "1"])

    let toolbox = try settings.makeToolbox(clientName: "test-agent")

    #expect(toolbox.client.environment.executable.path == tart.path)
    #expect(toolbox.client.environment.paths.home.path == home.path)
    #expect(toolbox.client.environment.extraVariables == ["TART_NO_AUTO_PRUNE": "1"])
    #expect(toolbox.clientName == "test-agent")
  }

  @Test func followsTheTartManagedByTartelette() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let managed = directory.url.appendingPathComponent("Managed", isDirectory: true)
    let tart = managed.appendingPathComponent("versions/2.41.0/tart.app/Contents/MacOS/tart")
    try FileManager.default.createDirectory(at: tart.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: tart)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tart.path)
    try FileManager.default.createSymbolicLink(
      atPath: managed.appendingPathComponent("current").path, withDestinationPath: "versions/2.41.0")

    let toolbox = try TarteletteSettings().makeToolbox(
      clientName: nil, managedTartLayout: ManagedTartLayout(root: managed))

    #expect(
      toolbox.client.environment.executable.path
        == managed.appendingPathComponent("current/tart.app/Contents/MacOS/tart").path)
    #expect(toolbox.client.environment.source == .managed(version: "2.41.0"))
  }
}
