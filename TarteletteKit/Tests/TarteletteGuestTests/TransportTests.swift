import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

@Suite("Guest transports and probe")
struct TransportTests {
  @Test func tartExecAddsInteractiveFlagOnlyWithStandardInput() async throws {
    let runner = RecordingRunner()
    let tart = URL(fileURLWithPath: "/opt/homebrew/bin/tart")
    let transport = TartExecTransport(vmName: "dev", tartExecutable: tart, environment: ["CI": "1"], runner: runner)
    _ = try await transport.run(["pbpaste"], standardInput: nil, timeout: .seconds(5))
    _ = try await transport.run(["pbcopy"], standardInput: Data("x".utf8), timeout: nil)

    let requests = runner.requests
    #expect(requests[0].executable == tart)
    #expect(requests[0].arguments == ["exec", "dev", "pbpaste"])
    #expect(requests[0].environment == ["CI": "1"])
    #expect(requests[0].timeout == .seconds(5))
    #expect(requests[1].arguments == ["exec", "-i", "dev", "pbcopy"])
    #expect(requests[1].standardInput == Data("x".utf8))
    #expect(transport.label == "tart exec dev")
  }

  @Test func runnerFailuresBecomeCommandOutput() async throws {
    struct ThrowingRunner: ProcessRunning {
      func run(_ request: ProcessRequest) async throws -> CommandOutput {
        throw ProcessRunError.failed(status: 2, message: "VM \"dev\" is not running")
      }
    }
    let transport = TartExecTransport(
      vmName: "dev", tartExecutable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:], runner: ThrowingRunner())
    let output = try await transport.run(["true"], standardInput: nil, timeout: nil)
    #expect(output.status == 2)
    #expect(GuestProbe.interpret(output) == .unavailable(reason: GuestProbe.Reason.notRunning))
  }

  @Test func sshWithPasswordUsesAskpassHelper() async throws {
    let runner = RecordingRunner()
    let directory = try TestFiles.temporaryDirectory("tartelette-askpass")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = SSHTransport(
      host: "192.168.64.3", user: "admin", password: "admin", identityFile: nil, runner: runner,
      askpassDirectory: directory)
    _ = try await transport.run(["echo", "two words"], standardInput: nil, timeout: nil)

    let request = try #require(runner.requests.first)
    #expect(request.executable.path == "/usr/bin/ssh")
    #expect(request.arguments.contains("StrictHostKeyChecking=no"))
    #expect(request.arguments.contains("UserKnownHostsFile=/dev/null"))
    #expect(!request.arguments.contains("BatchMode=yes"))
    #expect(request.arguments.contains("-n"))
    #expect(Array(request.arguments.suffix(2)) == ["admin@192.168.64.3", "echo 'two words'"])
    #expect(request.environment["SSH_ASKPASS_REQUIRE"] == "force")
    #expect(request.environment[SSHTransport.passwordVariable] == "admin")
    #expect(!request.arguments.joined(separator: " ").contains("admin@192.168.64.3 admin"))

    let helper = try #require(request.environment["SSH_ASKPASS"])
    let attributes = try FileManager.default.attributesOfItem(atPath: helper)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let script = try String(contentsOfFile: helper, encoding: .utf8)
    #expect(script.contains("$TARTELETTE_SSH_PASSWORD"))
    #expect(!script.contains("admin"), "the secret must never be written to disk")
  }

  @Test func sshWithoutPasswordUsesBatchMode() async throws {
    let runner = RecordingRunner()
    let key = URL(fileURLWithPath: "/Users/me/.ssh/id_ed25519")
    let transport = SSHTransport(host: "vm.local", user: "admin", password: nil, identityFile: key, runner: runner)
    _ = try await transport.run(["pbcopy"], standardInput: Data("x".utf8), timeout: nil)
    let request = try #require(runner.requests.first)
    #expect(request.arguments.contains("BatchMode=yes"))
    #expect(request.arguments.contains(key.path))
    #expect(!request.arguments.contains("-n"))
    #expect(request.environment.isEmpty)
    #expect(transport.label == "ssh admin@vm.local")
  }

  @Test func probeInterpretsOutputs() {
    #expect(
      GuestProbe.interpret(CommandOutput(status: 0, stdout: Data("admin\n501\nDarwin\nadmin\n".utf8)))
        == .available(user: "admin", isRoot: false))
    #expect(
      GuestProbe.interpret(CommandOutput(status: 0, stdout: Data("root\n0\nLinux\n".utf8)))
        == .available(user: "root", isRoot: true))
    #expect(
      GuestProbe.interpret(CommandOutput(status: 0, stdout: Data("admin\n501\nDarwin\nroot\n".utf8)))
        == .unavailable(reason: GuestProbe.Reason.loginWindow))
    let agentMissing = CommandOutput(
      status: 1,
      stderr: Data("Failed to connect to the VM using its control socket: x, is the Tart Guest Agent running?".utf8))
    #expect(GuestProbe.interpret(agentMissing) == .unavailable(reason: GuestProbe.Reason.agentMissing))
  }

  @Test func probeRunsLocallyAndMapsTimeouts() async {
    let status = await GuestProbe.probe(LocalTransport())
    #expect(status.isAvailable)

    let slow = ScriptedTransport { _, _ in throw ProcessRunError.timedOut(after: .seconds(8)) }
    #expect(await GuestProbe.probe(slow) == .unavailable(reason: GuestProbe.Reason.timedOut))
  }

  @Test func endpointsCompareByVMAndTransport() {
    let a = GuestEndpoint(vmName: "dev", os: .macOS, transport: ScriptedTransport(label: "t") { _, _ in CommandOutput(status: 0) })
    let b = GuestEndpoint(vmName: "dev", os: .macOS, transport: ScriptedTransport(label: "t") { _, _ in CommandOutput(status: 1) })
    let c = GuestEndpoint(vmName: "dev", os: .linux, transport: ScriptedTransport(label: "t") { _, _ in CommandOutput(status: 0) })
    #expect(a == b)
    #expect(a != c)
    #expect(Set([a, b, c]).count == 2)
  }
}
