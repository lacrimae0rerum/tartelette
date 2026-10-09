import AppKit
import Foundation
import Testing

@testable import TarteletteGuest

/// `writeObjects` hands items to the pasteboard server asynchronously. A short-lived writer such as
/// `osascript` that exits right after writing loses every item but the first unless it makes the
/// server take all of them first. Found end to end: copying two files reached the guest as one.
@Suite("Durable guest pasteboard writes")
struct DurableWriteTests {
  @Test func everyFileSurvivesTheWriterExiting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("durable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let names = ["a.txt", ".hidden", "c d.txt"]
    for name in names { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }

    let boardName = "tartelette-durable-\(UUID().uuidString)"
    let payload = try JSONSerialization.data(withJSONObject: [
      "items": [] as [Any], "files": names.map { directory.appendingPathComponent($0).path },
    ])
    let output = try await LocalTransport().run(
      GuestScripts.macOSWrite(pasteboardName: boardName), standardInput: payload, timeout: .seconds(30))
    #expect(output.status == 0, "\(output.stderrString)")

    // Read from this process, after the writer (osascript) has exited.
    let board = NSPasteboard(name: NSPasteboard.Name(boardName))
    defer { board.releaseGlobally() }
    let urls = (board.pasteboardItems ?? []).compactMap { item in
      item.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent
    }
    #expect(urls == names)
    let reply = try JSONDecoder().decode(MacOSWriteReply.self, from: output.stdout)
    #expect(reply.itemCount == names.count)
  }

  /// The loss only shows on the general pasteboard (named pasteboards keep every item), so this
  /// check uses it — saving and restoring the user's contents — and runs only when
  /// `TARTELETTE_GENERAL_PASTEBOARD_TESTS=1`.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TARTELETTE_GENERAL_PASTEBOARD_TESTS"] == "1"))
  @MainActor
  func everyFileSurvivesOnTheGeneralPasteboard() async throws {
    let general = NSPasteboard.general
    let saved = (general.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
      var flavours: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types { if let data = item.data(forType: type) { flavours[type] = data } }
      return flavours
    }
    defer {
      general.clearContents()
      general.writeObjects(saved.map { flavours in
        let item = NSPasteboardItem()
        for (type, data) in flavours { item.setData(data, forType: type) }
        return item
      })
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("durable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let names = ["a.txt", "b.txt", "c.txt"]
    for name in names { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
    let payload = try JSONSerialization.data(withJSONObject: [
      "items": [] as [Any], "files": names.map { directory.appendingPathComponent($0).path },
    ])

    for _ in 0..<3 {
      let output = try await LocalTransport().run(GuestScripts.macOSWrite(), standardInput: payload, timeout: .seconds(30))
      #expect(output.status == 0, "\(output.stderrString)")
      try await Task.sleep(for: .milliseconds(300))
      let urls = (general.pasteboardItems ?? []).compactMap { item in
        item.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent
      }
      #expect(urls == names)
    }
  }
}
