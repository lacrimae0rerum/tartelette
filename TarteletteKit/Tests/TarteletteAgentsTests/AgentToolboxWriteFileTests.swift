import Foundation
import TarteletteCore
import TarteletteGuest
import Testing

@testable import TarteletteAgents

// Serialized: these tests spawn many short processes, and running them all at once slows the
// process-based tests elsewhere enough to trip their real-time timeouts.
@Suite("Agent toolbox: writing guest files", .serialized)
struct AgentToolboxWriteFileTests {
  /// A harness with a running macOS VM "dev" shared at operate, whose "guest" is this Mac.
  private static func harness(limits: AgentLimits = AgentLimits()) throws -> ToolboxHarness {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .operate], limits: limits))
    try harness.tart.addVM("dev", state: "running")
    return harness
  }

  @Test func writeFileCreatesTheFileAndItsFolders() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("project/src/hello.txt").path

    let result = try await harness.toolbox(guest: LocalTransport()).writeFile(name: "dev", path: path, content: "hello\n")

    #expect(
      result
        == AgentWriteFileResult(
          path: path, bytesWritten: 6, sha256: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("hello\n".utf8))
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "write_file")
    #expect(entry.outcome == .ok)
  }

  @Test func writeFileDecodesBase64Content() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("blob.bin").path

    // Line breaks, as some encoders add them, are ignored.
    let result = try await harness.toolbox(guest: LocalTransport())
      .writeFile(name: "dev", path: path, content: "AP\n8Q", encoding: .base64)

    #expect(result.bytesWritten == 3)
    #expect(result.sha256 == "2da45f2cd1f9c8e69a67abf7a6b26c282533d0a7686787a9533265418680d4d2")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0x00, 0xFF, 0x10]))
  }

  @Test func writeFileRefusesBadContentBeforeReachingTheGuest() async throws {
    let harness = try Self.harness(limits: AgentLimits(maxFileBytes: 4))
    defer { harness.remove() }
    let path = harness.directory.file("out.txt").path
    let guest = LocalTransport()
    let toolbox = harness.toolbox(guest: guest)

    await #expect(throws: AgentFileError.invalidBase64) {
      try await toolbox.writeFile(name: "dev", path: path, content: "not base64!", encoding: .base64)
    }
    let tooLarge = await #expect(throws: AgentFileError.tooLarge(bytes: 5, limit: 4)) {
      try await toolbox.writeFile(name: "dev", path: path, content: "hello")
    }
    #expect(tooLarge?.localizedDescription.contains("5 bytes") == true)
    await #expect(throws: AgentFileError.invalidPath("out.txt")) {
      try await toolbox.writeFile(name: "dev", path: "out.txt", content: "hi")
    }
    #expect(guest.commands.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(harness.auditEntries.map(\.outcome) == [.failed, .failed, .failed])
  }

  @Test func writeFileCanRefuseToCreateFolders() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let folder = harness.directory.file("missing").path
    let toolbox = harness.toolbox(guest: LocalTransport())

    let error = await #expect(throws: AgentFileError.directoryNotFound(path: folder, vm: "dev")) {
      try await toolbox.writeFile(name: "dev", path: folder + "/a.txt", content: "a", createDirectories: false)
    }
    #expect(error?.localizedDescription == "The folder “\(folder)” doesn't exist in “dev”.")
    #expect(!FileManager.default.fileExists(atPath: folder))

    let sibling = harness.directory.file("b.txt").path
    _ = try await toolbox.writeFile(name: "dev", path: sibling, content: "b", createDirectories: false)
    #expect(try String(contentsOfFile: sibling, encoding: .utf8) == "b")
  }

  @Test func writeFileReplacesAnExistingFile() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("config.txt").path
    try Data("a much longer old content".utf8).write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)

    let result = try await harness.toolbox(guest: LocalTransport()).writeFile(name: "dev", path: path, content: "new")

    #expect(result.sha256 == "11507a0e2f5e69d5dfa40a62a1bd7b6ee57e6bcd85c67c9b8431b36fff21c437")
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "new")
    #expect(try Self.permissions(of: path) == 0o640)

    let emptied = try await harness.toolbox(guest: LocalTransport()).writeFile(name: "dev", path: path, content: "")
    #expect(emptied.bytesWritten == 0)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
  }

  @Test func newFilesGetTheGuestUsersDefaultPermissions() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("new/script.sh").path

    _ = try await harness.toolbox(guest: LocalTransport()).writeFile(name: "dev", path: path, content: "echo hi\n")

    let mask = try Self.shellUmask()
    #expect(try Self.permissions(of: path) == 0o666 & ~mask)
    #expect(try Self.permissions(of: harness.directory.file("new").path) == 0o777 & ~mask)
  }

  @Test func writeFileRefusesToReplaceAFolder() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let folder = harness.directory.url.path

    await #expect(throws: AgentFileError.isDirectory(path: folder, vm: "dev")) {
      try await harness.toolbox(guest: LocalTransport()).writeFile(name: "dev", path: folder, content: "x")
    }
  }

  @Test func aFailedUploadRemovesTheFileItCreated() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("new.txt").path

    await #expect(throws: GuestTransportError.self) {
      try await harness.toolbox(guest: FailingUploadTransport()).writeFile(name: "dev", path: path, content: "data")
    }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func aFailedUploadKeepsAFileThatAlreadyExisted() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("old.txt").path
    try Data("old".utf8).write(to: URL(fileURLWithPath: path))

    await #expect(throws: GuestTransportError.self) {
      try await harness.toolbox(guest: FailingUploadTransport()).writeFile(name: "dev", path: path, content: "new")
    }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "old")
  }

  @Test func writeFileExplainsAGuestAgentThatStopsAnswering() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    // The guest prepares the path, then the agent stops answering before the upload.
    let guest = ScriptedTransport { call in
      guard call.standardInput == nil else {
        return CommandOutput(
          status: 1,
          stderr: Data("Error: Failed to connect to the VM using its control socket: x, is the Tart Guest Agent running?".utf8))
      }
      return CommandOutput(status: 0, stdout: Data("existing\n".utf8))
    }

    await #expect(throws: AgentToolError.guestAgentUnreachable("dev")) {
      try await harness.toolbox(guest: guest).writeFile(name: "dev", path: "/tmp/x.txt", content: "x")
    }
    #expect(guest.calls.count == 2)
  }

  @Test func writeFileNeedsOperateAccessAndARunningVM() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .template, "off": .operate]))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    try harness.tart.addVM("off")
    let guest = LocalTransport()
    let toolbox = harness.toolbox(guest: guest)

    await #expect(throws: AgentDenial.notPermitted(vm: "dev", operation: .writeFile, access: .template)) {
      try await toolbox.writeFile(name: "dev", path: "/tmp/x.txt", content: "x")
    }
    await #expect(throws: AgentToolError.vmNotRunning("off")) {
      try await toolbox.writeFile(name: "off", path: "/tmp/x.txt", content: "x")
    }
    #expect(guest.commands.isEmpty)
    #expect(harness.auditEntries.map(\.outcome) == [.denied, .failed])
  }

  @Test func fileToolsNeverRecordContentInTheAuditLog() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = harness.directory.file("token.txt").path
    let secret = "ghp_secret-token-value"
    let toolbox = harness.toolbox(guest: LocalTransport())

    _ = try await toolbox.writeFile(name: "dev", path: path, content: secret)
    let read = try await toolbox.readFile(name: "dev", path: path)

    #expect(read.content == secret)
    #expect(harness.auditEntries.map(\.tool) == ["write_file", "read_file"])
    #expect(harness.auditEntries.allSatisfy { $0.detail?.contains(path) == true })
    #expect(!harness.auditLogText.contains(secret))
  }

  private static func permissions(of path: String) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
  }

  /// The umask a shell started by this process gets, as the "guest" scripts do.
  private static func shellUmask() throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "umask"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines), radix: 8))
  }
}

/// Runs commands on this Mac like `LocalTransport`, but fails every upload (the only commands that
/// receive stdin), as a guest whose disk fills up mid-transfer would.
private struct FailingUploadTransport: GuestTransport {
  let label = "failing-upload"
  let inner = LocalTransport()

  func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
    guard standardInput == nil else { return CommandOutput(status: 1, stderr: Data("No space left on device".utf8)) }
    return try await inner.run(command, standardInput: nil, timeout: timeout)
  }
}
