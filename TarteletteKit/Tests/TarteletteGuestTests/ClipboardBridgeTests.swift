import AppKit
import Foundation
import Testing

@testable import TarteletteGuest

/// End-to-end bridge tests: the macOS guest scripts run for real on this Mac against private named
/// pasteboards, with temporary folders standing in for the guest's staging area.
@Suite("Clipboard bridge")
struct ClipboardBridgeTests {
  struct Fixture {
    let bridge: ClipboardBridge
    let endpoint: GuestEndpoint
    let transport: LocalTransport
    let guestBoard: NSPasteboard
    let hostStaging: URL
    let guestStaging: URL

    func cleanUp() {
      guestBoard.releaseGlobally()
      try? FileManager.default.removeItem(at: hostStaging)
      try? FileManager.default.removeItem(at: guestStaging)
    }

    /// Waits until this process sees the guest pasteboard at the change count the bridge reported.
    ///
    /// The guest script writes from another process; on a loaded machine this process can take a
    /// moment to see the named pasteboard change, and reading its contents before then can return
    /// the previous (empty) state. Only the change count is awaited, so content that is still
    /// missing once the change is visible keeps failing the test's content expectations.
    func guestBoardCatchesUp(to state: GuestClipboardState, within timeout: Duration = .seconds(20)) async throws
      -> Bool
    {
      let deadline = ContinuousClock.now + timeout
      while guestBoard.changeCount != state.changeCount, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      return guestBoard.changeCount == state.changeCount
    }
  }

  static func makeFixture(simulatesStreamLoss: Bool = false) throws -> Fixture {
    let boardName = "tartelette-test-guest-\(UUID().uuidString)"
    let hostStaging = try TestFiles.temporaryDirectory("tartelette-host-staging")
    let guestStaging = try TestFiles.temporaryDirectory("tartelette-guest-staging")
    let transport = LocalTransport(simulatesStreamLoss: simulatesStreamLoss)
    let bridge = ClipboardBridge(
      fileStagingDirectory: hostStaging,
      options: .init(guestStagingRoot: guestStaging.path, guestPasteboardName: boardName))
    return Fixture(
      bridge: bridge,
      endpoint: GuestEndpoint(vmName: "local", os: .macOS, transport: transport),
      transport: transport,
      guestBoard: NSPasteboard(name: NSPasteboard.Name(boardName)),
      hostStaging: hostStaging,
      guestStaging: guestStaging)
  }

  static func richText() -> ClipboardPayload {
    let text = "Tartelette ✓ — héllo 🥧"
    let rtf = try! NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
      .data(from: NSRange(location: 0, length: (text as NSString).length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    return ClipboardPayload(items: [
      ClipboardRepresentation(type: ClipboardRepresentation.plainText, data: Data(text.utf8)),
      ClipboardRepresentation(type: ClipboardRepresentation.rtf, data: rtf),
      ClipboardRepresentation(type: ClipboardRepresentation.html, data: Data("<b>\(text)</b>".utf8)),
    ])
  }

  static func noisePNG(side: Int) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
    let noise = TestFiles.noise(count: side * side * 4)
    noise.withUnsafeBytes { bytes in rep.bitmapData!.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!, count: noise.count) }
    return rep.representation(using: .png, properties: [:])!
  }

  @Test func richTextRoundTripsWithIdenticalFingerprint() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let payload = Self.richText()

    let state = try await fixture.bridge.pushToGuest(payload, endpoint: fixture.endpoint)
    #expect(state.fingerprint == payload.fingerprint)
    #expect(try await fixture.guestBoardCatchesUp(to: state))
    #expect(fixture.guestBoard.string(forType: .string) == payload.plainText)

    let pulled = try #require(try await fixture.bridge.pullFromGuest(fixture.endpoint))
    #expect(pulled.fingerprint == payload.fingerprint)
    #expect(pulled.items.count == 3)
    #expect(try await fixture.bridge.guestChangeCount(fixture.endpoint) == state.changeCount)
  }

  @Test func largeImageUsesStagingAndSurvivesStreamLoss() async throws {
    let fixture = try Self.makeFixture(simulatesStreamLoss: true)
    defer { fixture.cleanUp() }
    let png = Self.noisePNG(side: 400)
    #expect(png.count > 512 * 1024)
    let payload = ClipboardPayload(items: [ClipboardRepresentation(type: ClipboardRepresentation.png, data: png)])

    let state = try await fixture.bridge.pushToGuest(payload, endpoint: fixture.endpoint)
    #expect(try await fixture.guestBoardCatchesUp(to: state))
    #expect(fixture.guestBoard.data(forType: .png) == png)

    let pulled = try #require(try await fixture.bridge.pullFromGuest(fixture.endpoint))
    #expect(pulled.fingerprint == payload.fingerprint)
    #expect(pulled.summary.hasPrefix("Image · PNG"))
    #expect(fixture.transport.corruptedStreams > 0)
    #expect(await fixture.bridge.chunkedTransferCount >= 2)
  }

  @Test func filesAndFoldersRoundTrip() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-source")
    defer { try? FileManager.default.removeItem(at: source) }
    let note = source.appendingPathComponent("Notes ✓.txt")
    try Data("hello from the host\n".utf8).write(to: note)
    let folder = source.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let blob = TestFiles.noise(count: 300 * 1024)
    try blob.write(to: folder.appendingPathComponent("inner.bin"))

    let payload = ClipboardPayload(files: [note, folder])
    let state = try await fixture.bridge.pushToGuest(payload, endpoint: fixture.endpoint)
    #expect(try await fixture.guestBoardCatchesUp(to: state))

    let guestURLs = try #require(
      fixture.guestBoard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
    #expect(guestURLs.map(\.lastPathComponent).sorted() == ["Folder", "Notes ✓.txt"])
    #expect(guestURLs.allSatisfy { $0.path.hasPrefix(fixture.guestStaging.resolvingSymlinksInPath().path) || $0.path.hasPrefix(fixture.guestStaging.path) })

    let pulled = try #require(try await fixture.bridge.pullFromGuest(fixture.endpoint))
    #expect(pulled.files.count == 2)
    #expect(pulled.fingerprint == payload.fingerprint)
    let pulledNote = try #require(pulled.files.first { $0.lastPathComponent == "Notes ✓.txt" })
    #expect(try Data(contentsOf: pulledNote) == Data("hello from the host\n".utf8))
    let pulledFolder = try #require(pulled.files.first { $0.lastPathComponent == "Folder" })
    #expect(try Data(contentsOf: pulledFolder.appendingPathComponent("inner.bin")) == blob)
    #expect(pulledNote.resolvingSymlinksInPath().path.hasPrefix(fixture.hostStaging.resolvingSymlinksInPath().path))
  }

  @Test func pullRespectsSizeLimitBeforeTransferring() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.bridge.pushToGuest(Self.richText(), endpoint: fixture.endpoint)
    await #expect(throws: GuestTransportError.self) {
      _ = try await fixture.bridge.pullFromGuest(fixture.endpoint, maxBytes: 4)
    }
  }

  @Test func verifiedTransferFallsBackToChunksOnStreamLoss() async throws {
    let fixture = try Self.makeFixture(simulatesStreamLoss: true)
    defer { fixture.cleanUp() }
    let data = TestFiles.noise(count: 700 * 1024)
    let path = fixture.guestStaging.appendingPathComponent("blob.bin").path

    try await fixture.bridge.upload(data, to: path, endpoint: fixture.endpoint)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
    #expect(await fixture.bridge.chunkedTransferCount == 1)

    let downloaded = try await fixture.bridge.download(path, endpoint: fixture.endpoint)
    #expect(downloaded == data)
    #expect(await fixture.bridge.chunkedTransferCount == 2)
  }

  @Test func fastPathIsUsedWhenStreamsAreIntact() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let data = TestFiles.noise(count: 700 * 1024)
    let path = fixture.guestStaging.appendingPathComponent("blob.bin").path
    try await fixture.bridge.upload(data, to: path, endpoint: fixture.endpoint)
    #expect(try await fixture.bridge.download(path, endpoint: fixture.endpoint) == data)
    #expect(await fixture.bridge.chunkedTransferCount == 0)
  }

  @Test func fileTransferNeverOverwrites() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let source = try TestFiles.temporaryDirectory("tartelette-source")
    defer { try? FileManager.default.removeItem(at: source) }
    let file = source.appendingPathComponent("report.txt")
    try Data("v1".utf8).write(to: file)
    let destination = fixture.guestStaging.appendingPathComponent("Desktop").path

    let first = try await GuestFileTransfer.send([file], to: fixture.endpoint, destination: destination, bridge: fixture.bridge)
    let second = try await GuestFileTransfer.send([file], to: fixture.endpoint, destination: destination, bridge: fixture.bridge)
    #expect(first.map { URL(fileURLWithPath: $0).lastPathComponent } == ["report.txt"])
    #expect(second.map { URL(fileURLWithPath: $0).lastPathComponent } == ["report 2.txt"])

    let back = try await GuestFileTransfer.receive(second, from: fixture.endpoint, to: fixture.hostStaging, bridge: fixture.bridge)
    #expect(back.count == 1)
    #expect(try Data(contentsOf: back[0]) == Data("v1".utf8))
  }
}
