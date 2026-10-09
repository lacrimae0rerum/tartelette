import AppKit
import Foundation
import Testing

@testable import TarteletteGuest

/// Found end to end with a macOS guest: shortly after a sync, a system component on the receiving
/// side can republish the clipboard with fewer files (hidden ones dropped). That reduced copy must
/// be recognised as an echo of the sync, not sent back to overwrite the original side.
@Suite("Degraded echoes", .serialized)
@MainActor
struct DegradedEchoTests {
  static func writeFileURLs(_ urls: [URL], to board: NSPasteboard) {
    board.clearContents()
    board.writeObjects(urls.map { url -> NSPasteboardItem in
      let item = NSPasteboardItem()
      item.setString(url.absoluteString, forType: .fileURL)
      return item
    })
  }

  static func fileURLs(on board: NSPasteboard) -> [String] {
    (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent }
  }

  static func makeFiles() throws -> (URL, [URL]) {
    let directory = try TestFiles.temporaryDirectory("degraded-echo")
    let urls = ["visible.txt", ".hidden", "data.bin"].map { directory.appendingPathComponent($0) }
    for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
    return (directory, urls)
  }

  @Test func aReducedGuestCopyOfAPushIsNotAppliedToTheHost() async throws {
    let harness = try ClipboardSyncSessionTests.makeHarness()
    defer { harness.tearDown() }
    let (directory, files) = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: directory) }
    harness.session.start()
    #expect(await waitUntil { harness.session.guestStatus.isAvailable })

    Self.writeFileURLs(files, to: harness.host)
    #expect(await waitUntil { Self.fileURLs(on: harness.fixture.guestBoard).count == 3 })
    #expect(await waitUntil { harness.log.sentCount == 1 })

    // A guest system component republishes the clipboard without the hidden file.
    let guestCopies = (harness.fixture.guestBoard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    Self.writeFileURLs(guestCopies.filter { !$0.lastPathComponent.hasPrefix(".") }, to: harness.fixture.guestBoard)
    try await Task.sleep(for: .seconds(1.5))

    #expect(harness.log.receivedCount == 0)
    #expect(Self.fileURLs(on: harness.host) == files.map(\.lastPathComponent), "the host keeps the original three files")
  }

  @Test func aReducedHostCopyOfAReceiveIsNotSentBack() async throws {
    let harness = try ClipboardSyncSessionTests.makeHarness()
    defer { harness.tearDown() }
    let (directory, files) = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: directory) }
    harness.session.start()
    #expect(await waitUntil { harness.session.guestStatus.isAvailable })

    Self.writeFileURLs(files, to: harness.fixture.guestBoard)
    #expect(await waitUntil { Self.fileURLs(on: harness.host).count == 3 })
    #expect(await waitUntil { harness.log.receivedCount == 1 })

    // A host system component republishes the clipboard without the hidden file.
    let hostCopies = (harness.host.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    Self.writeFileURLs(hostCopies.filter { !$0.lastPathComponent.hasPrefix(".") }, to: harness.host)
    try await Task.sleep(for: .seconds(1.5))

    #expect(harness.log.sentCount == 0)
    #expect(Self.fileURLs(on: harness.fixture.guestBoard) == files.map(\.lastPathComponent), "the guest keeps the original files")
  }
}
