import AppKit
import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

/// Promises a file URL lazily and, until `ready`, provides nothing — like a writer that hasn't
/// handed an item to the pasteboard server in time. (The server remembers a declined promise, so
/// once read unresolved the item stays unresolved; a later complete state is a new write.)
final class LazyFileURLProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let url: URL
  private var _ready = false

  init(url: URL) {
    self.url = url
  }

  var ready: Bool {
    get { lock.withLock { _ready } }
    set { lock.withLock { _ready = newValue } }
  }

  func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
    guard ready else { return }
    item.setString(url.absoluteString, forType: type)
  }
}

/// Found end to end with a macOS guest: writers that hand items over lazily sometimes leave one
/// unresolved when another process reads, and URL reading silently omits it — so a partial copy
/// (2 of 3 files) was synced. Unresolved file items must make the read incomplete and retried.
@Suite("Incomplete clipboard reads", .serialized)
@MainActor
struct IncompleteReadTests {
  static func makeFiles(_ names: [String]) throws -> (URL, [URL]) {
    let directory = try TestFiles.temporaryDirectory("incomplete-read")
    let urls = names.map { directory.appendingPathComponent($0) }
    for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
    return (directory, urls)
  }

  /// Writes one eager file URL item and one promised by `provider`.
  static func writeEagerAndLazy(_ eager: URL, _ provider: LazyFileURLProvider, to board: NSPasteboard) {
    let first = NSPasteboardItem()
    first.setString(eager.absoluteString, forType: .fileURL)
    let second = NSPasteboardItem()
    second.setDataProvider(provider, forTypes: [.fileURL])
    board.clearContents()
    board.writeObjects([first, second])
  }

  static func fileNames(on board: NSPasteboard) -> [String] {
    (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent }
  }

  static func writeEager(_ urls: [URL], to board: NSPasteboard) {
    board.clearContents()
    board.writeObjects(urls.map { url -> NSPasteboardItem in
      let item = NSPasteboardItem()
      item.setString(url.absoluteString, forType: .fileURL)
      return item
    })
  }

  @Test func captureIsIncompleteWhileAFileItemIsUnresolved() throws {
    let (directory, files) = try Self.makeFiles(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let board = NSPasteboard(name: NSPasteboard.Name("tartelette-incomplete-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let provider = LazyFileURLProvider(url: files[1])
    Self.writeEagerAndLazy(files[0], provider, to: board)

    #expect(PasteboardCodec.capture(board) == .incomplete)
    #expect(PasteboardCodec.snapshot(board) == nil)

    Self.writeEager(files, to: board)
    guard case .complete(let payload?) = PasteboardCodec.capture(board) else {
      Issue.record("expected a complete capture once every item resolves")
      return
    }
    #expect(payload.files.map(\.lastPathComponent) == ["a.txt", "b.txt"])
  }

  @Test func sessionNeverSendsAPartialCopyAndSendsTheCompleteOne() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let (directory, files) = try Self.makeFiles(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = SyncSettlingTests.hostBoard()
    defer { host.releaseGlobally() }
    let session = SyncSettlingTests.makeSession(fixture, transport: fixture.transport, host: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    let provider = LazyFileURLProvider(url: files[1])
    Self.writeEagerAndLazy(files[0], provider, to: host)
    try await Task.sleep(for: .seconds(1))
    #expect(log.sentCount == 0, "a partial copy must not be sent")
    #expect(Self.fileNames(on: fixture.guestBoard).isEmpty)

    // The writer completes its copy.
    Self.writeEager(files, to: host)
    #expect(await waitUntil { Self.fileNames(on: fixture.guestBoard).count == 2 })
    #expect(Self.fileNames(on: fixture.guestBoard) == ["a.txt", "b.txt"])
    #expect(await waitUntil { log.sentCount == 1 })
  }

  @Test func bridgeReportsIncompleteGuestManifests() async throws {
    let transport = ScriptedTransport { _, _ in
      CommandOutput(status: 0, stdout: Data(#"{"changeCount":5,"incomplete":true,"items":[],"files":[]}"#.utf8))
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let bridge = ClipboardBridge(fileStagingDirectory: staging)
    do {
      _ = try await bridge.pullFromGuest(GuestEndpoint(vmName: "vm", os: .macOS, transport: transport))
      Issue.record("an incomplete guest clipboard must not be read")
    } catch {
      #expect(error as? GuestTransferError == .incomplete)
    }
  }

  @Test func sessionRetriesIncompleteGuestReadsSilently() async throws {
    let reads = SyncSettlingTests.Counter()
    let queries = SyncSettlingTests.Counter()
    let transport = ScriptedTransport { command, _ in
      let joined = command.joined(separator: " ")
      if command.first == "/usr/bin/env" {
        return CommandOutput(status: 0, stdout: Data("admin\n501\nDarwin\nadmin\n".utf8))
      }
      if joined.contains("emit({ changeCount: Number(board(argv[0]).changeCount) })") {
        queries.increment()
        // The first poll learns 6; the guest then changes to 7.
        return CommandOutput(status: 0, stdout: Data(#"{"changeCount":\#(queries.count == 1 ? 6 : 7)}"#.utf8))
      }
      if joined.contains("readFileItems") {
        reads.increment()
        if reads.count <= 2 {
          return CommandOutput(status: 0, stdout: Data(#"{"changeCount":7,"incomplete":true,"items":[],"files":[]}"#.utf8))
        }
        let text = Data("complete".utf8).base64EncodedString()
        return CommandOutput(
          status: 0,
          stdout: Data(#"{"changeCount":7,"items":[{"type":"public.utf8-plain-text","data":"\#(text)"}],"files":[]}"#.utf8))
      }
      return CommandOutput(status: 0)
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let host = SyncSettlingTests.hostBoard()
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "vm", os: .macOS, transport: transport),
      bridge: ClipboardBridge(fileStagingDirectory: staging),
      configuration: .init(direction: .guestToHost, guestPollInterval: .milliseconds(100), guestSettleDelay: .zero),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }

    #expect(await waitUntil(timeout: .seconds(5)) { host.string(forType: .string) == "complete" })
    #expect(reads.count >= 3)
    let failures = log.events.filter { if case .failed = $0 { true } else { false } }
    #expect(failures.isEmpty, "incomplete reads are retried silently: \(failures)")
    let unavailable = log.events.filter {
      if case .guestStatus(.unavailable) = $0 { true } else { false }
    }
    #expect(unavailable.isEmpty, "incomplete reads must not make the guest look unreachable")
  }
}

extension IncompleteReadTests {
  /// An item that never resolves is reported once, instead of the copy silently never syncing.
  @Test func aPersistentlyUnresolvedItemIsReportedOnce() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let (directory, files) = try Self.makeFiles(["a.txt", "b.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = SyncSettlingTests.hostBoard()
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: fixture.endpoint, bridge: fixture.bridge,
      configuration: .init(hostPollInterval: .milliseconds(60), guestPollInterval: .milliseconds(150), incompleteReportDelay: .milliseconds(500)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    Self.writeEagerAndLazy(files[0], LazyFileURLProvider(url: files[1]), to: host)
    try await Task.sleep(for: .seconds(1.5))
    #expect(log.sentCount == 0)
    #expect(log.skipped.filter { $0.contains("couldn't be read") }.count == 1, "\(log.skipped)")
  }
}
