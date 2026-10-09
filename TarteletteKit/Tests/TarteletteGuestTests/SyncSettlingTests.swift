import AppKit
import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

/// Review round 2: torn pasteboard reads, failure classification and staging cleanup.
@Suite("Sync settling and failure handling", .serialized)
@MainActor
struct SyncSettlingTests {
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  /// Records what a scripted guest was asked, in order.
  final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
  }

  static func fileItem(_ url: URL) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(url.absoluteString, forType: .fileURL)
    return item
  }

  static func fileNames(_ board: NSPasteboard) -> [String] {
    ((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
      .map(\.lastPathComponent)
  }

  static func makeSession(
    _ fixture: ClipboardBridgeTests.Fixture, transport: any GuestTransport, host: NSPasteboard,
    hostPoll: Duration = .milliseconds(60), guestPoll: Duration = .milliseconds(150)
  ) -> ClipboardSyncSession {
    ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "local", os: .macOS, transport: transport),
      bridge: fixture.bridge,
      configuration: .init(hostPollInterval: hostPoll, guestPollInterval: guestPoll),
      hostPasteboard: host)
  }

  static func hostBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
  }

  // MARK: Torn host reads

  /// Writers clear the pasteboard (bumping the change count) and only then add their items (which
  /// doesn't bump it). Reads in between must never settle on the partial, empty state.
  @Test func clearThenLateWriteIsSentOnceWithEveryFile() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-torn")
    defer { try? FileManager.default.removeItem(at: source) }
    let visible = source.appendingPathComponent("visible.txt")
    let hidden = source.appendingPathComponent(".oculto")
    try Data("a\n".utf8).write(to: visible)
    try Data("b\n".utf8).write(to: hidden)

    let host = Self.hostBoard()
    defer { host.releaseGlobally() }
    let session = Self.makeSession(fixture, transport: fixture.transport, host: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    host.clearContents()
    try await Task.sleep(for: .milliseconds(350))  // several polls see the cleared pasteboard
    host.writeObjects([Self.fileItem(visible), Self.fileItem(hidden)])

    #expect(await waitUntil { Self.fileNames(fixture.guestBoard).count == 2 })
    try await Task.sleep(for: .seconds(1))
    #expect(Set(Self.fileNames(fixture.guestBoard)) == ["visible.txt", ".oculto"])
    #expect(log.sentCount == 1, "exactly one send, carrying both files")
    #expect(log.receivedCount == 0, "the files must not come back to the host")
  }

  /// Items appended within one poll of each other travel together.
  @Test func itemsAppendedWithinOnePollTravelTogether() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-torn")
    defer { try? FileManager.default.removeItem(at: source) }
    let first = source.appendingPathComponent("first.txt")
    let second = source.appendingPathComponent("second.txt")
    try Data("1".utf8).write(to: first)
    try Data("2".utf8).write(to: second)

    let host = Self.hostBoard()
    defer { host.releaseGlobally() }
    let session = Self.makeSession(fixture, transport: fixture.transport, host: host, hostPoll: .milliseconds(100))
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    host.clearContents()
    host.writeObjects([Self.fileItem(first)])
    try await Task.sleep(for: .milliseconds(30))
    host.writeObjects([Self.fileItem(second)])  // appended: no change-count bump

    #expect(await waitUntil { Self.fileNames(fixture.guestBoard).count == 2 })
    try await Task.sleep(for: .seconds(1))
    #expect(log.sentCount == 1)
  }

  // MARK: Guest settle

  /// When the guest change count moves, the session waits until it stops moving before pulling.
  @Test func guestChangesSettleBeforeThePull() async throws {
    let counts = [5, 6, 7, 7]
    let reads = Counter()
    let queries = Counter()
    let commands = CommandLog()
    let transport = ScriptedTransport { command, _ in
      let joined = command.joined(separator: " ")
      if command.first == "/usr/bin/env" {
        return CommandOutput(status: 0, stdout: Data("admin\n501\nDarwin\nadmin\n".utf8))
      }
      if joined.contains("emit({ changeCount: Number(board(argv[0]).changeCount) })") {
        let value = counts[min(queries.count, counts.count - 1)]
        queries.increment()
        commands.append("count=\(value)")
        return CommandOutput(status: 0, stdout: Data("{\"changeCount\":\(value)}".utf8))
      }
      if joined.contains("readObjectsForClassesOptions") {
        reads.increment()
        commands.append("read")
        let text = Data("settled".utf8).base64EncodedString()
        let manifest = "{\"changeCount\":7,\"items\":[{\"type\":\"public.utf8-plain-text\",\"data\":\"\(text)\"}],\"files\":[]}"
        return CommandOutput(status: 0, stdout: Data(manifest.utf8))
      }
      return CommandOutput(status: 0)
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let host = Self.hostBoard()
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "vm", os: .macOS, transport: transport),
      bridge: ClipboardBridge(fileStagingDirectory: staging),
      configuration: .init(
        direction: .guestToHost, guestPollInterval: .milliseconds(100), guestSettleDelay: .milliseconds(80)),
      hostPasteboard: host)
    session.start()
    defer { session.stop() }

    #expect(await waitUntil(timeout: .seconds(5)) { host.string(forType: .string) == "settled" })
    try await Task.sleep(for: .milliseconds(500))
    #expect(reads.count == 1)
    let log = commands.all
    let readIndex = try #require(log.firstIndex(of: "read"))
    #expect(Array(log[..<readIndex].suffix(2)) == ["count=7", "count=7"], "pulled before the count settled: \(log)")
  }

  // MARK: Failure classification

  @Test func connectivityFailuresAreTypedAsUnreachable() async throws {
    let transport = ScriptedTransport { _, _ in
      CommandOutput(
        status: 1,
        stderr: Data("Failed to connect to the VM using its control socket: deadline, is the Tart Guest Agent running?".utf8))
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let bridge = ClipboardBridge(fileStagingDirectory: staging)
    do {
      _ = try await bridge.guestChangeCount(GuestEndpoint(vmName: "vm", os: .macOS, transport: transport))
      Issue.record("expected a failure")
    } catch {
      #expect(error as? GuestTransportError == .unreachable(GuestProbe.Reason.agentMissing))
    }

    #expect(ClipboardSyncSession.failureKind(of: GuestTransportError.unreachable("x")) == .transient)
    #expect(ClipboardSyncSession.failureKind(of: ProcessRunError.timedOut(after: .seconds(1))) == .transient)
    #expect(
      ClipboardSyncSession.failureKind(of: GuestTransportError.commandFailed(status: 1, message: "Permission denied"))
        == .permanent)
    #expect(ClipboardSyncSession.failureKind(of: GuestTransportError.unexpectedOutput("?")) == .permanent)
  }

  /// A deterministic guest failure (permission denied, disk full…) is reported once and not
  /// retried, and it doesn't make the guest look unreachable.
  @Test func persistentGuestFailuresAreNotRetried() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let controllable = ControllableTransport(wrapping: fixture.transport)
    let attempts = Counter()
    controllable.failWhen = { command in
      let isWrite = command.contains { $0.contains("fileHandleWithStandardInput") }
      if isWrite { attempts.increment() }
      return isWrite
    }
    let host = Self.hostBoard()
    defer { host.releaseGlobally() }
    let session = Self.makeSession(fixture, transport: controllable, host: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    host.clearContents()
    host.setString("cannot be written", forType: .string)
    #expect(await waitUntil { attempts.count > 0 })
    try await Task.sleep(for: .seconds(1.5))
    #expect(attempts.count == 1, "retried \(attempts.count) times")
    let failures = log.events.filter { if case .failed = $0 { true } else { false } }
    #expect(failures.count == 1)
    let statuses = log.events.compactMap { event -> GuestAgentStatus? in
      if case .guestStatus(let status) = event { status } else { nil }
    }
    #expect(!statuses.contains { if case .unavailable = $0 { true } else { false } }, "status flapped: \(statuses)")
  }

  /// A guest change whose pull fails transiently is retried, not dropped.
  @Test func guestChangesSurviveATransientPullFailure() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let controllable = ControllableTransport(wrapping: fixture.transport)
    let host = Self.hostBoard()
    defer { host.releaseGlobally() }
    let session = Self.makeSession(fixture, transport: controllable, host: host)
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    let failedReads = Counter()
    controllable.unreachableWhen = { command in
      let isRead = command.contains { $0.contains("readObjectsForClassesOptions") }
      if isRead { failedReads.increment() }
      return isRead
    }
    fixture.guestBoard.clearContents()
    fixture.guestBoard.setString("made while the link was flaky", forType: .string)
    #expect(await waitUntil { failedReads.count > 0 })
    controllable.unreachableWhen = nil
    #expect(await waitUntil { host.string(forType: .string) == "made while the link was flaky" })
  }

  // MARK: Linux size check

  @Test func unparsableLinuxFileSizesFailClosed() async throws {
    let archives = Counter()
    let transport = ScriptedTransport { command, _ in
      let joined = command.joined(separator: " ")
      if joined.contains("text/uri-list") {
        let manifest = "{\"changeCount\":1,\"items\":[],\"files\":[{\"uri\":\"file:///home/admin/big.iso\"}]}"
        return CommandOutput(status: 0, stdout: Data(manifest.utf8))
      }
      if joined.contains("du -sk") { return CommandOutput(status: 0, stdout: Data("du: cannot access\n".utf8)) }
      if joined.contains("tar -czf") { archives.increment() }
      return CommandOutput(status: 0)
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let bridge = ClipboardBridge(fileStagingDirectory: staging)
    let endpoint = GuestEndpoint(vmName: "linux", os: .linux, transport: transport)
    do {
      _ = try await bridge.pullFromGuest(endpoint, maxBytes: 1024)
      Issue.record("an unknown size must not pass the limit check")
    } catch {
      guard case GuestTransportError.unexpectedOutput = error else {
        Issue.record("expected unexpectedOutput, got \(error)")
        return
      }
    }
    #expect(archives.count == 0, "nothing may be copied when the size is unknown")
  }

  // MARK: Guest archives

  @Test func failedExtractionRemovesTheUploadedArchive() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-src")
    defer { try? FileManager.default.removeItem(at: source) }
    let file = source.appendingPathComponent("doc.txt")
    try Data("hello".utf8).write(to: file)

    do {
      _ = try await fixture.bridge.sendFiles([file], to: fixture.endpoint, guestDirectory: "/dev/null/cannot-exist")
      Issue.record("extraction into an impossible folder must fail")
    } catch {}
    let leftovers = (FileManager.default.subpaths(atPath: fixture.guestStaging.path) ?? []).filter { $0.hasSuffix(".tgz") }
    #expect(leftovers.isEmpty, "left behind: \(leftovers)")
  }

  @Test func pruningAlsoRemovesStrayArchives() async throws {
    let root = try TestFiles.temporaryDirectory("tartelette-staging-root")
    defer { try? FileManager.default.removeItem(at: root) }
    var names: [String] = []
    for index in 0..<4 {
      let name = "\(UUID().uuidString).tgz"
      let url = root.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: Double(index) * 60 - 600)], ofItemAtPath: url.path)
      names.append(name)
    }
    try Data("y".utf8).write(to: root.appendingPathComponent("keep-me.tgz"))

    let output = try await LocalTransport().run(
      GuestScripts.pruneStaging(root.path, keep: 2, os: .macOS), standardInput: nil, timeout: .seconds(20))
    #expect(output.succeeded)
    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    #expect(remaining == Set(names.suffix(2)).union(["keep-me.tgz"]))
  }
}
