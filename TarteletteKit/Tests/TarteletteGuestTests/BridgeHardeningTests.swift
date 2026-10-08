import AppKit
import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

/// Regression tests for the native review findings on the bridge (R3-001…R3-003, R3-007…R3-009,
/// R3-011).
@Suite("Clipboard bridge hardening")
struct BridgeHardeningTests {
  // MARK: R3-001 hidden files

  @Test func receivedHiddenFilesAreReturned() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let guestFolder = fixture.guestStaging.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: guestFolder, withIntermediateDirectories: true)
    try Data("SECRET=1\n".utf8).write(to: guestFolder.appendingPathComponent(".env"))
    try Data("visible\n".utf8).write(to: guestFolder.appendingPathComponent("visible.txt"))

    let local = try await fixture.bridge.receiveFiles(
      [guestFolder.appendingPathComponent(".env").path, guestFolder.appendingPathComponent("visible.txt").path],
      from: fixture.endpoint, into: fixture.hostStaging)
    #expect(local.map(\.lastPathComponent).sorted() == [".env", "visible.txt"])
    let env = try #require(local.first { $0.lastPathComponent == ".env" })
    #expect(try Data(contentsOf: env) == Data("SECRET=1\n".utf8))
  }

  // MARK: R3-002 duplicate names and leading dashes

  @Test func duplicateNamesAreRejectedBeforeTransferring() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-source")
    defer { try? FileManager.default.removeItem(at: source) }
    let a = source.appendingPathComponent("a/report.txt")
    let b = source.appendingPathComponent("b/report.txt")
    for file in [a, b] {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(file.path.utf8).write(to: file)
    }

    await #expect(throws: GuestTransferError.duplicateNames(["report.txt"])) {
      _ = try await fixture.bridge.sendFiles([a, b], to: fixture.endpoint, guestDirectory: fixture.guestStaging.path)
    }
    await #expect(throws: GuestTransferError.duplicateNames(["report.txt"])) {
      _ = try await fixture.bridge.receiveFiles([a.path, b.path], from: fixture.endpoint, into: fixture.hostStaging)
    }
    #expect(fixture.transport.commands.isEmpty, "nothing may run in the guest for a rejected transfer")
  }

  @Test func namesStartingWithADashSurviveBothDirections() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-source")
    defer { try? FileManager.default.removeItem(at: source) }
    let dashed = source.appendingPathComponent("-rf.txt")
    let option = source.appendingPathComponent("--help")
    try Data("dash".utf8).write(to: dashed)
    try Data("option".utf8).write(to: option)
    let destination = fixture.guestStaging.appendingPathComponent("Desktop").path

    let guestPaths = try await fixture.bridge.sendFiles([dashed, option], to: fixture.endpoint, guestDirectory: destination)
    #expect(guestPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() == ["--help", "-rf.txt"])
    let back = try await fixture.bridge.receiveFiles(guestPaths, from: fixture.endpoint, into: fixture.hostStaging)
    #expect(back.map(\.lastPathComponent).sorted() == ["--help", "-rf.txt"])
    #expect(try Data(contentsOf: try #require(back.first { $0.lastPathComponent == "-rf.txt" })) == Data("dash".utf8))
  }

  @Test func guestPathsWithTildeAreExpandedInTheGuest() async throws {
    let home = try TestFiles.temporaryDirectory("tartelette-home")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
    try Data("from home".utf8).write(to: home.appendingPathComponent("Desktop/note.txt"))
    let staging = try TestFiles.temporaryDirectory("tartelette-host-staging")
    defer { try? FileManager.default.removeItem(at: staging) }
    let endpoint = GuestEndpoint(vmName: "local", os: .macOS, transport: LocalTransport(environment: ["HOME": home.path]))
    let bridge = ClipboardBridge(fileStagingDirectory: staging, options: .init(guestStagingRoot: "~/tartelette-staging"))

    let local = try await bridge.receiveFiles(["~/Desktop/note.txt"], from: endpoint, into: staging)
    #expect(local.map(\.lastPathComponent) == ["note.txt"])
    #expect(try Data(contentsOf: local[0]) == Data("from home".utf8))
  }

  @Test func guestPathSplitting() {
    #expect(GuestScripts.splitGuestPath("~/Desktop/report.pdf") == ("~/Desktop", "report.pdf"))
    #expect(GuestScripts.splitGuestPath("/Users/admin/folder/") == ("/Users/admin", "folder"))
    #expect(GuestScripts.splitGuestPath("/etc") == ("/", "etc"))
    #expect(GuestScripts.splitGuestPath("notes.txt") == (".", "notes.txt"))
  }

  // MARK: R3-003 fingerprints follow file contents

  @Test func fileFingerprintsChangeWithContentsAndStayStableOtherwise() throws {
    let directory = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.txt")
    try Data("version A".utf8).write(to: file)
    let original = ClipboardPayload(files: [file]).fingerprint
    #expect(ClipboardPayload(files: [file]).fingerprint == original, "unchanged files keep their fingerprint")

    // Same name, same length, different bytes, same modification time.
    let modified = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    try Data("version B".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    #expect(ClipboardPayload(files: [file]).fingerprint != original)

    // Folders notice edits inside them.
    let folder = directory.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let inner = folder.appendingPathComponent("inner.txt")
    try Data("one".utf8).write(to: inner)
    let folderPrint = ClipboardPayload(files: [folder]).fingerprint
    try Data("two".utf8).write(to: inner)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: inner.path)
    #expect(ClipboardPayload(files: [folder]).fingerprint != folderPrint)
  }

  // MARK: R3-007 size limits and includeFiles before transferring

  @Test func filesAreNotPulledWhenExcludedOrTooLarge() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-source")
    defer { try? FileManager.default.removeItem(at: source) }
    let file = source.appendingPathComponent("big.bin")
    try TestFiles.noise(count: 64 * 1024).write(to: file)
    _ = try await fixture.bridge.pushToGuest(ClipboardPayload(files: [file]), endpoint: fixture.endpoint)

    #expect(try await fixture.bridge.pullFromGuest(fixture.endpoint, includeFiles: false) == nil)
    await #expect(throws: GuestTransportError.self) {
      _ = try await fixture.bridge.pullFromGuest(fixture.endpoint, maxBytes: 1024)
    }
    #expect(Self.stagingFolders(in: fixture.hostStaging).isEmpty, "nothing may be copied to the host")
  }

  @Test func stagedMacOSPayloadIsRemovedWhenTheDownloadFails() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let controllable = ControllableTransport(wrapping: fixture.transport)
    let endpoint = GuestEndpoint(vmName: "local", os: .macOS, transport: controllable)
    let bridge = ClipboardBridge(
      fileStagingDirectory: fixture.hostStaging,
      options: .init(
        inlineLimit: 8, guestStagingRoot: fixture.guestStaging.path, guestPasteboardName: fixture.guestBoard.name.rawValue))
    _ = try await bridge.pushToGuest(ClipboardBridgeTests.richText(), endpoint: endpoint)

    controllable.failWhen = { command in command.contains { $0.contains("exec cat") } }
    await #expect(throws: GuestTransportError.self) { _ = try await bridge.pullFromGuest(endpoint) }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.guestStaging.path).filter { $0.hasSuffix(".json") }
    #expect(leftovers.isEmpty)
  }

  // MARK: R3-008 bounded staging

  @Test func hostStagingKeepsOnlyRecentFolders() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let bridge = ClipboardBridge(
      fileStagingDirectory: fixture.hostStaging,
      options: .init(
        guestStagingRoot: fixture.guestStaging.path, guestPasteboardName: fixture.guestBoard.name.rawValue,
        stagingFoldersToKeep: 2))
    let source = try TestFiles.temporaryDirectory("tartelette-source")
    defer { try? FileManager.default.removeItem(at: source) }

    var last: ClipboardPayload?
    for index in 0..<4 {
      let file = source.appendingPathComponent("file-\(index).txt")
      try Data("\(index)".utf8).write(to: file)
      _ = try await bridge.pushToGuest(ClipboardPayload(files: [file]), endpoint: fixture.endpoint)
      last = try await bridge.pullFromGuest(fixture.endpoint)
    }
    #expect(Self.stagingFolders(in: fixture.hostStaging).count == 2)
    #expect(Self.stagingFolders(in: fixture.guestStaging).count == 2)
    let latest = try #require(last?.files.first)
    #expect(try Data(contentsOf: latest) == Data("3".utf8), "the newest pull must survive pruning")
  }

  @Test func guestPruningIsScopedToTheStagingRoot() async throws {
    let root = try TestFiles.temporaryDirectory("tartelette-prune")
    defer { try? FileManager.default.removeItem(at: root) }
    var folders: [URL] = []
    for age in [300.0, 200.0, 100.0] {
      let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: folder.path)
      folders.append(folder)
    }
    let unrelated = root.appendingPathComponent("keep-me", isDirectory: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("payload.json"))

    let output = try await LocalTransport().run(GuestScripts.pruneStaging(root.path, keep: 1, os: .macOS), standardInput: nil, timeout: nil)
    #expect(output.succeeded)
    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    #expect(remaining == [folders[2].lastPathComponent, "keep-me", "payload.json"])

    // A folder that isn't a Tartelette staging root is never touched.
    let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-\(UUID().uuidString)", isDirectory: true)
    let victim = foreign.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: foreign) }
    _ = try await LocalTransport().run(GuestScripts.pruneStaging(foreign.path, keep: 0, os: .macOS), standardInput: nil, timeout: nil)
    #expect(FileManager.default.fileExists(atPath: victim.path))
  }

  // MARK: R3-009 error wording

  @Test func guestErrorsKeepTheirOwnMessage() async throws {
    let transport = ScriptedTransport { _, _ in
      CommandOutput(status: 1, stderr: Data("mkdir: /Library/x: Permission denied".utf8))
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let bridge = ClipboardBridge(fileStagingDirectory: staging)
    let endpoint = GuestEndpoint(vmName: "vm", os: .macOS, transport: transport)
    do {
      try await bridge.upload(Data("x".utf8), to: "/Library/x/file", endpoint: endpoint)
      Issue.record("upload should fail")
    } catch {
      let message = error.localizedDescription
      #expect(message.contains("Permission denied"))
      #expect(message.contains("copy data into the guest"))
      #expect(!message.contains("SSH"))
    }
  }

  @Test func sshWordingOnlyAppliesToSSHConnectionFailures() async throws {
    let runner = RecordingRunner()
    runner.output = CommandOutput(status: 255, stderr: Data("admin@vm: Permission denied (publickey,password).".utf8))
    let ssh = SSHTransport(host: "vm", user: "admin", password: nil, identityFile: nil, runner: runner)
    #expect(await GuestProbe.probe(ssh) == .unavailable(reason: GuestProbe.Reason.sshAuth))

    #expect(
      GuestProbe.commandReason(for: "Permission denied", status: 1, operation: "write", isSSH: true)
        == "Couldn't write: Permission denied")
    #expect(
      GuestProbe.commandReason(for: "Permission denied (publickey)", status: 255, operation: "write", isSSH: true)
        == GuestProbe.Reason.sshAuth)
    #expect(
      GuestProbe.commandReason(for: "connection timed out", status: 1, operation: "write", isSSH: false)
        == "Couldn't write: connection timed out")
    #expect(GuestProbe.commandReason(for: "", status: 125, operation: "write", isSSH: false).contains("could not start"))
  }

  // MARK: R3-011 Linux guests

  @Test func linuxPushStoresThePlainTextProjection() async throws {
    let linux = try FakeLinuxClipboard()
    defer { linux.cleanUp() }
    let staging = try TestFiles.temporaryDirectory("tartelette-host-staging")
    defer { try? FileManager.default.removeItem(at: staging) }
    let endpoint = GuestEndpoint(vmName: "linux", os: .linux, transport: linux.transport())
    let bridge = ClipboardBridge(fileStagingDirectory: staging)
    let rich = ClipboardBridgeTests.richText()

    let state = try await bridge.pushToGuest(rich, endpoint: endpoint)
    #expect(linux.targets == ["text/plain"])
    #expect(linux.target("text/plain") == rich.data(for: ClipboardRepresentation.plainText))
    let projection = ClipboardPayload(items: [
      ClipboardRepresentation(type: ClipboardRepresentation.plainText, data: rich.data(for: ClipboardRepresentation.plainText)!)
    ])
    #expect(state.fingerprint == projection.fingerprint)
    #expect(state.fingerprint != rich.fingerprint)
    #expect(try await bridge.guestChangeCount(endpoint) == state.changeCount)

    let pulled = try #require(try await bridge.pullFromGuest(endpoint))
    #expect(pulled.fingerprint == state.fingerprint)
  }

  @Test func linuxPullsCheckLimitsFirstAndCleanUp() async throws {
    let linux = try FakeLinuxClipboard()
    defer { linux.cleanUp() }
    let staging = try TestFiles.temporaryDirectory("tartelette-host-staging")
    defer { try? FileManager.default.removeItem(at: staging) }
    let endpoint = GuestEndpoint(vmName: "linux", os: .linux, transport: linux.transport())
    let bridge = ClipboardBridge(fileStagingDirectory: staging)
    let guestRoot = linux.home.appendingPathComponent(".cache/tartelette/clipboard")

    try linux.own("text/plain", Data(repeating: 0x61, count: 2000))
    await #expect(throws: GuestTransportError.tooLarge(bytes: 2000, limit: 10)) {
      _ = try await bridge.pullFromGuest(endpoint, maxBytes: 10)
    }
    let items = (try? FileManager.default.contentsOfDirectory(atPath: guestRoot.path)) ?? []
    #expect(items.filter { $0.hasPrefix("item.") }.isEmpty, "staged flavours must be removed after a refused pull")

    // Files: refused before anything is copied, and skipped entirely when excluded.
    let folder = linux.home.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("data.bin")
    try TestFiles.noise(count: 40 * 1024).write(to: file)
    try linux.own("text/uri-list", Data(file.absoluteString.utf8))
    await #expect(throws: GuestTransportError.self) { _ = try await bridge.pullFromGuest(endpoint, maxBytes: 1024) }
    #expect(try await bridge.pullFromGuest(endpoint, includeFiles: false) == nil)
    #expect(Self.stagingFolders(in: staging).isEmpty)

    let pulled = try #require(try await bridge.pullFromGuest(endpoint))
    #expect(pulled.files.map(\.lastPathComponent) == ["data.bin"])
    #expect(try Data(contentsOf: pulled.files[0]) == Data(contentsOf: file))
  }

  static func stagingFolders(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { UUID(uuidString: $0) != nil }
  }
}
