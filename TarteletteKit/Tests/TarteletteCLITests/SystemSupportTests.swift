import Foundation
import TarteletteCore
import Testing

@testable import TarteletteCLI

@Suite("Capabilities, credentials and system helpers")
struct SystemSupportTests {
  static let realTart = "/opt/homebrew/bin/tart"

  @Test func parsesDumpHelpFixture() throws {
    let json = #"""
      {"serializationVersion":0,"command":{"commandName":"tart","arguments":[],"subcommands":[
        {"commandName":"run","shouldDisplay":true,"arguments":[
          {"kind":"positional","shouldDisplay":true},
          {"kind":"flag","names":[{"kind":"long","name":"net-host"}],"shouldDisplay":true},
          {"kind":"option","names":[{"kind":"long","name":"dir"}],"isRepeating":true}]},
        {"commandName":"exec","arguments":[{"kind":"flag","names":[{"kind":"short","name":"i"}]}]},
        {"commandName":"clone","arguments":[{"kind":"flag","names":[{"kind":"long","name":"deduplicate"}],"shouldDisplay":false}]}
      ]}}
      """#
    let capabilities = try TartCapabilities.parse(dumpHelp: Data(json.utf8))
    #expect(capabilities.isKnown)
    #expect(capabilities.supports("run"))
    #expect(capabilities.supports("run", option: "--net-host"))
    #expect(capabilities.supports("run", option: "dir"))
    #expect(!capabilities.supports("run", option: "--provisioning-opts"))
    #expect(capabilities.supports("exec", option: "-i"))
    #expect(capabilities.supports("clone", option: "--deduplicate"))
    #expect(!capabilities.supports("suspend"))
    #expect(TartCapabilities.unknown.supports("anything", option: "--whatever"))
  }

  @Test func clientCachesCapabilitiesFromFakeTart() async throws {
    let fake = try FakeTart()
    defer { fake.remove() }
    let client = fake.client
    let capabilities = await client.capabilities()
    #expect(capabilities.supports("exec", option: "-i"))
    #expect(!capabilities.supports("run"))
    try FileManager.default.removeItem(at: fake.directory.appendingPathComponent("args---experimental-dump-help.txt"))
    _ = await client.capabilities()
    #expect(fake.recorded("args---experimental-dump-help.txt").isEmpty, "second call should hit the cache")
  }

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realTart)))
  func readsCapabilitiesOfInstalledTart() async throws {
    let client = TartClient(environment: TartEnvironment(executable: URL(fileURLWithPath: Self.realTart)))
    let capabilities = await client.capabilities()
    #expect(capabilities.isKnown)
    #expect(capabilities.supports("run", option: "--no-graphics"))
    #expect(capabilities.supports("set", option: "--no-display-refit"))
    #expect(capabilities.supports("exec", option: "-t"))
    #expect(capabilities.supports("prune", option: "--gc"))
  }

  @Test func readsDockerConfigHostsWithoutSecrets() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let docker = home.appendingPathComponent(".docker")
    try FileManager.default.createDirectory(at: docker, withIntermediateDirectories: true)
    try Data(
      #"{"auths":{"ghcr.io":{"auth":"c2VjcmV0"},"https://index.docker.io/v1/":{}},"credHelpers":{"123.dkr.ecr.us-east-1.amazonaws.com":"ecr-login"}}"#
        .utf8
    ).write(to: docker.appendingPathComponent("config.json"))

    let accounts = RegistryCredentialStore.dockerConfigHosts(home: home)
    #expect(
      accounts.map(\.host) == ["123.dkr.ecr.us-east-1.amazonaws.com", "ghcr.io", "index.docker.io"])
    #expect(accounts.allSatisfy { $0.source == .dockerConfig && $0.username == nil })
  }

  @Test func readsEnvironmentCredentials() {
    #expect(RegistryCredentialStore.environmentAccounts(environment: [:]).isEmpty)
    #expect(
      RegistryCredentialStore.environmentAccounts(environment: ["TART_REGISTRY_USERNAME": "ci"]).isEmpty)
    let scoped = RegistryCredentialStore.environmentAccounts(environment: [
      "TART_REGISTRY_USERNAME": "ci", "TART_REGISTRY_PASSWORD": "x", "TART_REGISTRY_HOSTNAME": "ghcr.io",
    ])
    #expect(scoped == [RegistryAccount(host: "ghcr.io", username: "ci", source: .environment)])
    let global = RegistryCredentialStore.environmentAccounts(environment: [
      "TART_REGISTRY_USERNAME": "ci", "TART_REGISTRY_PASSWORD": "x",
    ])
    #expect(global.first?.host == "*")
  }

  @Test func keychainQueryDoesNotCrash() {
    for account in RegistryCredentialStore.keychainAccounts() {
      #expect(!account.host.isEmpty)
      #expect(account.source == .keychain)
    }
  }

  @Test func softnetPrivilegeScriptIsQuoted() {
    let script = SoftnetSupport.privilegeScript(for: URL(fileURLWithPath: "/opt/home brew/bin/soft\"net"))
    #expect(script.hasPrefix("do shell script \"chown root '/opt/home brew/bin/soft\\\"net'"))
    #expect(script.hasSuffix("\" with administrator privileges"))
    #expect(script.contains("&& chmod u+s"))
  }

  @Test func softnetDetection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-softnet-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let softnet = directory.appendingPathComponent("softnet")
    try Data("#!/bin/sh\n".utf8).write(to: softnet)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: softnet.path)

    #expect(SoftnetSupport.locate(searchPath: "/nonexistent:\(directory.path)") == softnet)
    #expect(SoftnetSupport.locate(searchPath: "/nonexistent") == nil)
    #expect(!SoftnetSupport.isPrivileged(softnet))
  }

  @Test func softnetPrivilegesPropagateRunnerFailures() async throws {
    struct DeniedRunner: ProcessRunning {
      func run(_ request: ProcessRequest) async throws -> CommandOutput {
        CommandOutput(status: 1, stderr: Data("execution error: User canceled. (-128)".utf8))
      }
    }
    await #expect(throws: ProcessRunError.cancelled) {
      try await SoftnetSupport.enablePrivileges(for: URL(fileURLWithPath: "/tmp/softnet"), runner: DeniedRunner())
    }
  }

  @Test func listsBridgeableInterfaces() {
    let interfaces = NetworkInterfaces.bridgeable()
    #expect(Set(interfaces.map(\.bsdName)).count == interfaces.count)
    #expect(interfaces.allSatisfy { !$0.bsdName.isEmpty })
  }

  @Test func terminalScriptIsExecutableAndSelfDeleting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-term-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try TerminalLauncher.makeScript(
      commandLine: "/opt/homebrew/bin/tart exec -it dev zsh -l", title: "dev — Shell", directory: directory)

    #expect(script.pathExtension == "command")
    #expect(FileManager.default.isExecutableFile(atPath: script.path))
    let body = try String(contentsOf: script, encoding: .utf8)
    #expect(body.hasPrefix("#!/bin/zsh\n"))
    #expect(body.contains("rm -f -- \"$0\""))
    #expect(body.contains("exec /opt/homebrew/bin/tart exec -it dev zsh -l"))
    #expect(body.contains("'dev — Shell'"))
  }

  /// Runs `script` as Terminal would, without Terminal, and returns what its command printed.
  private func runTerminalScript(_ script: URL, home: URL) throws -> String {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = [script.path]
    // No TERM: `clear` complains on stderr and the script goes on.
    shell.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
    let output = Pipe()
    shell.standardOutput = output
    shell.standardError = FileHandle.nullDevice
    try shell.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    shell.waitUntilExit()
    #expect(shell.terminationStatus == 0)
    // The title escape sequence ends with BEL; the command's output follows it.
    let text = String(decoding: data, as: UTF8.self)
    let afterTitle = text.split(separator: "\u{07}", omittingEmptySubsequences: false).last ?? ""
    return afterTitle.trimmingCharacters(in: .newlines)
  }

  @Test func terminalScriptPutsTheTartDirectoryFirstOnPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-term-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    // A managed Tart lives under "Application Support": spaces (and any quote) must survive.
    let tartDirectory = URL(fileURLWithPath: "/Volumes/Tart's Disk/Application Support/tart.app/Contents/MacOS")
    let script = try TerminalLauncher.makeScript(
      commandLine: "/usr/bin/printenv PATH", title: "PATH", directory: directory, tartDirectory: tartDirectory)

    #expect(
      try runTerminalScript(script, home: directory)
        == "/Volumes/Tart's Disk/Application Support/tart.app/Contents/MacOS:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    )
  }

  @Test func terminalScriptWithoutATartDirectoryKeepsTheUsualPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-term-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try TerminalLauncher.makeScript(commandLine: "/usr/bin/printenv PATH", title: "PATH", directory: directory)

    #expect(try runTerminalScript(script, home: directory) == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
  }
}
