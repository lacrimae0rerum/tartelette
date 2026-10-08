import AppKit
import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

@Suite("Clipboard payloads, codec and guest scripts")
struct PayloadAndScriptTests {
  @Test func fingerprintIgnoresFlavourOrder() {
    let text = ClipboardRepresentation(type: ClipboardRepresentation.plainText, data: Data("a".utf8))
    let html = ClipboardRepresentation(type: ClipboardRepresentation.html, data: Data("<i>a</i>".utf8))
    #expect(ClipboardPayload(items: [text, html]).fingerprint == ClipboardPayload(items: [html, text]).fingerprint)
    #expect(ClipboardPayload(items: [text]).fingerprint != ClipboardPayload(items: [html]).fingerprint)
  }

  @Test func summaries() throws {
    let text = ClipboardPayload(items: [ClipboardRepresentation(type: ClipboardRepresentation.plainText, data: Data("hello".utf8))])
    #expect(text.summary == "Text · 5 characters")
    #expect(text.plainText == "hello")
    let rich = ClipboardPayload(items: text.items + [ClipboardRepresentation(type: ClipboardRepresentation.rtf, data: Data("{\\rtf1}".utf8))])
    #expect(rich.summary == "Rich text · 5 characters")
    let image = ClipboardPayload(items: [ClipboardRepresentation(type: ClipboardRepresentation.png, data: Data(count: 2048))])
    #expect(image.summary.hasPrefix("Image · PNG · "))
    #expect(ClipboardPayload().isEmpty)

    let directory = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = directory.appendingPathComponent("a.txt")
    let b = directory.appendingPathComponent("b.txt")
    try Data(count: 10).write(to: a)
    try Data(count: 20).write(to: b)
    let files = ClipboardPayload(files: [a, b])
    #expect(files.totalByteCount == 30)
    #expect(files.summary.hasPrefix("2 files · "))
    #expect(ClipboardPayload(files: [a]).summary.hasPrefix("a.txt · "))
  }

  @MainActor
  @Test func codecRoundTripsOnAPrivatePasteboard() {
    let board = NSPasteboard(name: NSPasteboard.Name("tartelette-test-codec-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let payload = ClipboardBridgeTests.richText()
    let changeCount = PasteboardCodec.write(payload, to: board)
    #expect(changeCount == board.changeCount)
    let snapshot = PasteboardCodec.snapshot(board)
    #expect(snapshot?.fingerprint == payload.fingerprint)
  }

  @MainActor
  @Test func codecConvertsTIFFOnlyImagesToPNG() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("tartelette-test-codec-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
    board.clearContents()
    board.setData(rep.tiffRepresentation, forType: .tiff)

    let snapshot = try #require(PasteboardCodec.snapshot(board))
    #expect(snapshot.items.map(\.type) == [ClipboardRepresentation.png])
    #expect(NSBitmapImageRep(data: snapshot.items[0].data)?.pixelsWide == 8)
  }

  @MainActor
  @Test func codecPrefersFiles() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("tartelette-test-codec-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let directory = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("doc.txt")
    try Data("x".utf8).write(to: file)
    board.clearContents()
    board.writeObjects([file as NSURL, "doc.txt" as NSString])

    let snapshot = try #require(PasteboardCodec.snapshot(board))
    #expect(snapshot.files.map(\.lastPathComponent) == ["doc.txt"])
    #expect(snapshot.items.isEmpty)
  }

  @Test func userCommandGuardsLocaleAndConsoleUser() {
    let macOS = GuestScripts.userCommand(["pbpaste"], os: .macOS)
    #expect(macOS.prefix(2) == ["/bin/sh", "-c"])
    #expect(macOS[2].contains("launchctl asuser"))
    #expect(macOS[2].contains("LANG=en_US.UTF-8"))
    #expect(Array(macOS.suffix(2)) == ["tartelette", "pbpaste"])
    let linux = GuestScripts.userCommand(["xclip"], os: .linux)
    #expect(linux[2].contains("LANG=C.UTF-8"))
    #expect(!linux[2].contains("launchctl"))
  }

  /// Every generated shell script must at least parse under POSIX `sh -n`.
  @Test(arguments: [
    GuestScripts.fileInfo("~/a", os: .linux),
    GuestScripts.readFile("~/a", os: .linux),
    GuestScripts.chunkHashes("~/a", chunkSize: 131_072, os: .linux),
    GuestScripts.readChunk("~/a", index: 2, chunkSize: 131_072, os: .linux),
    GuestScripts.writeFile("~/a", os: .linux),
    GuestScripts.truncateFile("~/a", os: .linux),
    GuestScripts.writeChunk("~/a", index: 1, chunkSize: 131_072, os: .linux),
    GuestScripts.remove(["~/a", "/tmp/b"], os: .linux),
    GuestScripts.createArchive("~/a.tgz", paths: ["/tmp/x", "~/y"], os: .linux),
    GuestScripts.pathSizes(["~/a", "/tmp/b"], os: .linux),
    GuestScripts.pruneStaging("~/.cache/tartelette/clipboard", keep: 4, os: .linux),
    GuestScripts.extractArchive("~/a.tgz", into: "~/Desktop", os: .linux),
    GuestScripts.linuxChangeCount(),
    GuestScripts.linuxRead(stagingDirectory: "~/.cache/tartelette/clipboard"),
    GuestScripts.linuxWrite(mime: "text/plain", stagedFile: "~/.cache/x.bin"),
    GuestMetricsCollector.command(for: .linux),
    GuestMetricsCollector.command(for: .macOS),
  ])
  func shellScriptsParse(_ command: [String]) async throws {
    // Outer guard: `/bin/sh -c <guard> tartelette <inner…>`; inner scripts are `/bin/sh -c <script>`.
    var scripts = [command[2]]
    if command.count > 6, command[4] == "/bin/sh", command[5] == "-c" { scripts.append(command[6]) }
    for script in scripts {
      let output = try await LocalTransport().run(["/bin/sh", "-n", "-c", script], standardInput: nil, timeout: nil)
      #expect(output.succeeded, "sh -n failed: \(output.stderrString)")
    }
  }

  @Test func extractArchiveSuffixesClashingNames() async throws {
    let directory = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("1".utf8).write(to: source.appendingPathComponent("photo.jpeg"))
    try Data("2".utf8).write(to: source.appendingPathComponent("README"))
    let destination = directory.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: destination.appendingPathComponent("photo.jpeg"))
    try Data("old".utf8).write(to: destination.appendingPathComponent("README"))

    let archive = directory.appendingPathComponent("a.tgz")
    try await HostArchiver.archive(
      [source.appendingPathComponent("photo.jpeg"), source.appendingPathComponent("README")], to: archive)
    let output = try await LocalTransport().run(
      GuestScripts.extractArchive(archive.path, into: destination.path, os: .macOS), standardInput: nil, timeout: nil)
    #expect(output.succeeded)
    let created = output.stdoutString.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }.sorted()
    #expect(created == ["README 2", "photo 2.jpeg"])
    #expect(try String(contentsOf: destination.appendingPathComponent("photo.jpeg"), encoding: .utf8) == "old")
    #expect(!FileManager.default.fileExists(atPath: archive.path))
  }
}
