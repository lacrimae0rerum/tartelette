import Foundation
import TarteletteCore
import Testing

@testable import TarteletteCLI

@Suite("Tart client")
struct TartClientTests {
  @Test func setsCIAndHomebrewPathForRegularCommands() async throws {
    let fake = try FakeTart(customHome: true)
    defer { fake.remove() }
    _ = try await fake.client.list()

    let environment = fake.recordedEnvironment("list")
    #expect(environment["CI"] == "1")
    #expect(environment["PATH"]?.split(separator: ":").contains("/opt/homebrew/bin") == true)
    #expect(environment["TART_HOME"] == fake.environment.paths.home.path)
    #expect(environment["FAKE_TART_DIR"] == fake.directory.path)
  }

  @Test func variablesOmitCIForRun() throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    #expect(fake.environment.variables(forRun: true)["CI"] == nil)
    #expect(fake.environment.variables(forRun: false)["CI"] == "1")
    #expect(fake.environment.searchPath.contains(fake.directory.path))
  }

  @Test func parsesListAndDetails() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let client = fake.client

    let rows = try await client.list()
    #expect(rows.map(\.name) == ["dev", "ghcr.io/cirruslabs/ubuntu:latest"])
    #expect(rows[0].state == .running)
    #expect(rows[1].source == .oci)
    #expect(fake.recorded("args-list.txt") == "list\n--format\njson\n")

    let details = try await client.details(of: "dev")
    #expect(details.os == .macOS)
    #expect(details.memoryMB == 8192)
    #expect(details.sizeGB == 12.345)
    #expect(details.display == "1024x768pt")
  }

  @Test func resolvesIPAndVersion() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    #expect(try await fake.client.ipAddress(IPOptions(name: "dev", waitSeconds: 5, resolver: .agent)) == "192.168.64.7")
    #expect(fake.recorded("args-ip.txt") == "ip\ndev\n--wait\n5\n--resolver\nagent\n")
    #expect(try await fake.client.version() == "2.40.1")
  }

  @Test func loginSendsPasswordOnStandardInputOnly() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    try await fake.client.login(LoginOptions(host: "ghcr.io", username: "octocat"), password: "s3cr3t!")

    #expect(fake.recorded("stdin-login.txt") == "s3cr3t!")
    let arguments = fake.recorded("args-login.txt")
    #expect(!arguments.contains("s3cr3t!"))
    #expect(arguments == "login\nghcr.io\n--username\noctocat\n--password-stdin\n")
  }

  @Test func throwsCleanedUsageErrors() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    await #expect {
      try await fake.client.execute(.rename(name: "a", newName: "b"))
    } throws: { error in
      guard let error = error as? TartError else { return false }
      return error.isUsageError
        && error.message == "failed to rename VM a, target VM b already exists, delete it first!"
        && error.command == "tart rename a b"
    }
  }

  @Test func throwsVMStateErrors() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    await #expect {
      try await fake.client.execute(.stop(name: "ghost"))
    } throws: { error in
      (error as? TartError)?.isVMStateError == true && (error as? TartError)?.message == "VM \"ghost\" is not running"
    }
  }

  @Test func cleanMessageDropsNoise() {
    let raw = """
      Failed to perform garbage collection: busy
      Error: LessThanMinimalResourcesError: VM should have 4 CPU cores at minimum (requested 2)
      Usage: tart set <name>
        See 'tart set --help' for more information.
      """
    #expect(TartError.cleanMessage(raw) == "LessThanMinimalResourcesError: VM should have 4 CPU cores at minimum (requested 2)")
    #expect(TartError.cleanMessage("Failed to perform garbage collection: busy") == "Failed to perform garbage collection: busy")
  }

  @Test func readsConfigurationDirectly() throws {
    let fake = try FakeTart(customHome: true)
    defer { fake.remove() }
    let configFile = fake.environment.paths.configFile("dev")
    try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"os":"darwin","cpuCount":4,"cpuCountMin":4,"memorySize":8589934592,"memorySizeMin":4294967296,"display":{"width":1920,"height":1080,"unit":"pt"},"displayRefit":true,"macAddress":"aa:bb:cc:dd:ee:ff"}"#
        .utf8
    ).write(to: configFile)

    let config = try fake.client.configuration(of: "dev")
    #expect(config.operatingSystem == .macOS)
    #expect(config.displayRefit == true)
    #expect(config.display?.unit == "pt")
  }

  @Test func signallingAStoppedVMThrows() throws {
    let fake = try FakeTart(customHome: true)
    defer { fake.remove() }
    #expect(fake.client.runningProcessIdentifier(ofVM: "ghost") == nil)
    #expect {
      try fake.client.send(.requestGuestShutdown, toVM: "ghost")
    } throws: { error in
      (error as? TartError)?.isVMStateError == true
    }
  }

  @Test func detectsInstalledTartOrPreferredPath() throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let detected = TartEnvironment.detect(preferredExecutablePath: fake.executable.path, tartHome: "~/custom-tart-home")
    #expect(detected?.executable == fake.executable)
    #expect(detected?.paths.home.lastPathComponent == "custom-tart-home")
    #expect(detected?.usesCustomHome == true)
  }
}
