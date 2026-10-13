import Foundation
import Testing

@testable import TarteletteAgents

// Serialized: these tests spawn many short processes, and running them all at once slows the
// process-based tests elsewhere enough to trip their real-time timeouts.
@Suite("Agent toolbox: reading guest files", .serialized)
struct AgentToolboxReadFileTests {
  /// A harness with a running macOS VM "dev" shared at operate, whose "guest" is this Mac.
  private static func harness(limits: AgentLimits = AgentLimits()) throws -> ToolboxHarness {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .operate], limits: limits))
    try harness.tart.addVM("dev", state: "running")
    return harness
  }

  /// Writes a file in the harness directory and returns its absolute path.
  private static func file(_ name: String, _ contents: Data, in harness: ToolboxHarness) throws -> String {
    let url = harness.directory.file(name)
    try contents.write(to: url)
    return url.path
  }

  @Test func readFileReturnsASmallTextFile() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = try Self.file("notes.txt", Data("héllo\n".utf8), in: harness)

    let result = try await harness.toolbox(guest: LocalTransport()).readFile(name: "dev", path: path)

    #expect(
      result
        == AgentReadFileResult(
          path: path, content: "héllo\n", encoding: .utf8, offset: 0, length: 7, size: 7, endOfFile: true))
    let entry = try harness.onlyAuditEntry()
    #expect(entry.tool == "read_file")
    #expect(entry.outcome == .ok)
  }

  @Test func readFilePagesThroughABigFile() async throws {
    let harness = try Self.harness(limits: AgentLimits(maxOutputBytes: 4))
    defer { harness.remove() }
    let path = try Self.file("digits.txt", Data("0123456789".utf8), in: harness)
    let toolbox = harness.toolbox(guest: LocalTransport())

    let pages = [
      try await toolbox.readFile(name: "dev", path: path),
      try await toolbox.readFile(name: "dev", path: path, offset: 4, length: 100),
      try await toolbox.readFile(name: "dev", path: path, offset: 8),
      try await toolbox.readFile(name: "dev", path: path, offset: 10),
      try await toolbox.readFile(name: "dev", path: path, offset: 1, length: 2),
    ]

    #expect(pages.map(\.content) == ["0123", "4567", "89", "", "12"])
    #expect(pages.map(\.offset) == [0, 4, 8, 10, 1])
    #expect(pages.map(\.length) == [4, 4, 2, 0, 2])
    #expect(pages.map(\.endOfFile) == [false, false, true, true, false])
    #expect(pages.allSatisfy { $0.size == 10 })
    #expect(harness.auditEntries.count == 5)
  }

  @Test func readFileReadsAnEmptyFile() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = try Self.file("empty.txt", Data(), in: harness)

    let result = try await harness.toolbox(guest: LocalTransport()).readFile(name: "dev", path: path)

    #expect(
      result == AgentReadFileResult(path: path, content: "", encoding: .utf8, offset: 0, length: 0, size: 0, endOfFile: true))
  }

  @Test func readFileRemovesItsTemporaryCopy() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = try Self.file("notes.txt", Data("hello".utf8), in: harness)
    let guestTemporary = harness.directory.file("guest-tmp")
    try FileManager.default.createDirectory(at: guestTemporary, withIntermediateDirectories: true)
    let guest = LocalTransport(environment: ["TMPDIR": guestTemporary.path])

    _ = try await harness.toolbox(guest: guest).readFile(name: "dev", path: path, offset: 1)

    #expect(guest.commands.count > 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: guestTemporary.path).isEmpty)
  }

  @Test func readFileReturnsBinaryContentAsBase64() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = try Self.file("blob.bin", Data([0x00, 0xFF, 0x10]), in: harness)

    let result = try await harness.toolbox(guest: LocalTransport()).readFile(name: "dev", path: path)

    #expect(result.encoding == .base64)
    #expect(result.content == "AP8Q")
    #expect(result.length == 3)
  }

  @Test func aPageEndingInsideACharacterStopsBeforeIt() async throws {
    let harness = try Self.harness(limits: AgentLimits(maxOutputBytes: 4))
    defer { harness.remove() }
    // "é" takes bytes 3 and 4, so a 4-byte page would end inside it.
    let path = try Self.file("menu.txt", Data("caf\u{e9}s".utf8), in: harness)
    let toolbox = harness.toolbox(guest: LocalTransport())

    let first = try await toolbox.readFile(name: "dev", path: path)
    let second = try await toolbox.readFile(name: "dev", path: path, offset: first.offset + first.length)

    #expect(first.encoding == .utf8)
    #expect(first.content == "caf")
    #expect(first.length == 3)
    #expect(!first.endOfFile)
    #expect(second.encoding == .utf8)
    #expect(second.content == "\u{e9}s")
    #expect(second.endOfFile)
  }

  // MARK: Errors

  @Test func readFileExplainsPathsItCannotRead() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = try Self.file("short.txt", Data("abc".utf8), in: harness)
    let missing = harness.directory.file("missing.txt").path
    let directory = harness.directory.url.path
    let toolbox = harness.toolbox(guest: LocalTransport())

    let notFound = await #expect(throws: AgentFileError.notFound(path: missing, vm: "dev")) {
      try await toolbox.readFile(name: "dev", path: missing)
    }
    #expect(notFound?.localizedDescription == "There is no file at “\(missing)” in “dev”.")
    await #expect(throws: AgentFileError.isDirectory(path: directory, vm: "dev")) {
      try await toolbox.readFile(name: "dev", path: directory)
    }
    await #expect(throws: AgentFileError.notRegularFile(path: "/dev/null", vm: "dev")) {
      try await toolbox.readFile(name: "dev", path: "/dev/null")
    }
    await #expect(throws: AgentFileError.offsetBeyondEnd(path: path, offset: 4, size: 3)) {
      try await toolbox.readFile(name: "dev", path: path, offset: 4)
    }
    #expect(harness.auditEntries.map(\.outcome) == [.failed, .failed, .failed, .failed])
  }

  @Test(arguments: ["", "notes.txt", "~/notes.txt", "/tmp/a\u{0}b", "/" + String(repeating: "a", count: 1024)])
  func readFileRejectsInvalidPathsBeforeReachingTheGuest(path: String) async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let guest = LocalTransport()

    await #expect(throws: AgentFileError.invalidPath(path)) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: path)
    }
    #expect(guest.commands.isEmpty)
    #expect(try harness.onlyAuditEntry().outcome == .failed)
  }

  @Test func readFileAcceptsAPathOfExactly1024Bytes() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = "/" + String(repeating: "a", count: 1023)

    await #expect(throws: AgentFileError.notFound(path: path, vm: "dev")) {
      try await harness.toolbox(guest: LocalTransport()).readFile(name: "dev", path: path)
    }
  }

  @Test func readFileRejectsANegativeOffset() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let guest = LocalTransport()

    await #expect(throws: AgentFileError.invalidOffset(-1)) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: "/etc/hosts", offset: -1)
    }
    #expect(guest.commands.isEmpty)
  }

  @Test func readFileReportsAnUnreadableFile() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let path = try Self.file("locked.txt", Data("secret".utf8), in: harness)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }

    await #expect(
      throws: AgentFileError.guestFailure(operation: "read", path: path, vm: "dev", detail: "Permission denied")
    ) {
      try await harness.toolbox(guest: LocalTransport()).readFile(name: "dev", path: path)
    }
  }

  @Test func readFileExplainsAGuestAgentThatDoesNotAnswer() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let guest = ScriptedTransport(
      status: 1, stderr: "Error: Failed to connect to the VM using its control socket: x, is the Tart Guest Agent running?")

    await #expect(throws: AgentToolError.guestAgentUnreachable("dev")) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: "/etc/hosts")
    }
  }

  @Test func readFileRefusesOutputItDoesNotUnderstand() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    let guest = ScriptedTransport(status: 0, stdout: "file lots /tmp/x\n")

    let error = await #expect(throws: (any Error).self) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: "/etc/hosts")
    }
    #expect(error?.localizedDescription.contains("unexpected output") == true)
    #expect(guest.calls.count == 1)
  }

  // MARK: Refusals

  @Test func readFileNeedsOperateAccessAndAgentsOn() async throws {
    let harness = try ToolboxHarness(policy: AgentPolicy(enabled: true, vms: ["dev": .read]))
    defer { harness.remove() }
    try harness.tart.addVM("dev", state: "running")
    let guest = LocalTransport()

    await #expect(throws: AgentDenial.notPermitted(vm: "dev", operation: .readFile, access: .read)) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: "/etc/hosts")
    }
    try harness.savePolicy(AgentPolicy(enabled: false, vms: ["dev": .operate]))
    await #expect(throws: AgentDenial.agentsDisabled) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: "/etc/hosts")
    }
    #expect(guest.commands.isEmpty)
    #expect(harness.tart.calls.isEmpty)
    #expect(harness.auditEntries.map(\.outcome) == [.denied, .denied])
  }

  @Test func readFileNeedsARunningVM() async throws {
    let harness = try Self.harness()
    defer { harness.remove() }
    try harness.tart.setState("stopped", of: "dev")
    let guest = LocalTransport()

    await #expect(throws: AgentToolError.vmNotRunning("dev")) {
      try await harness.toolbox(guest: guest).readFile(name: "dev", path: "/etc/hosts")
    }
    #expect(guest.commands.isEmpty)
  }
}
