import Foundation
import TarteletteKit
import Testing

@testable import Tartelette

@Suite("Configuration draft")
struct ConfigurationDraftTests {
  private func config(refit: Bool? = nil, unit: String? = nil) throws -> VMConfigFile {
    var display: [String: Any] = ["width": 1024, "height": 768]
    if let unit { display["unit"] = unit }
    var object: [String: Any] = [
      "os": "darwin", "cpuCount": 4, "cpuCountMin": 4, "memorySize": 8 * 1024 * 1024 * 1024,
      "memorySizeMin": 4 * 1024 * 1024 * 1024, "display": display,
    ]
    if let refit { object["displayRefit"] = refit }
    return try JSONDecoder().decode(VMConfigFile.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func listing(diskGB: Double?) -> VMListing {
    VMListing(name: "vm", source: .local, diskGB: diskGB, sizeGB: 1, lastAccessed: nil, state: .stopped)
  }

  @Test func unchangedDraftOnlyCarriesRefitForward() throws {
    let draft = try #require(ConfigurationDraft(config: config(refit: false), listing: listing(diskGB: 50)))
    let options = draft.setOptions(name: "vm", baseline: draft)
    #expect(options.cpuCount == nil)
    #expect(options.memoryMB == nil)
    #expect(options.display == nil)
    #expect(options.diskSizeGB == nil)
    // Tart resets displayRefit on every `set` that omits it, so it is always re-passed.
    #expect(options.displayRefit == false)
  }

  @Test func changedDisplayKeepsItsUnit() throws {
    let baseline = try #require(ConfigurationDraft(config: config(unit: "pt"), listing: listing(diskGB: 50)))
    var draft = baseline
    draft.width = 1920
    draft.height = 1080
    #expect(draft.setOptions(name: "vm", baseline: baseline).display == "1920x1080pt")
  }

  @Test func diskOnlyGrows() throws {
    let baseline = try #require(ConfigurationDraft(config: config(), listing: listing(diskGB: 50)))
    var draft = baseline
    draft.diskSizeGB = 80
    #expect(draft.setOptions(name: "vm", baseline: baseline).diskSizeGB == 80)
    draft.diskSizeGB = 40
    #expect(draft.setOptions(name: "vm", baseline: baseline).diskSizeGB == nil)
  }

  @Test func unknownCapacityNeverResizes() throws {
    let baseline = try #require(ConfigurationDraft(config: config(), listing: listing(diskGB: nil)))
    #expect(!baseline.isDiskCapacityKnown)
    var draft = baseline
    draft.diskSizeGB = 10
    #expect(draft.setOptions(name: "vm", baseline: baseline).diskSizeGB == nil)
    #expect(!draft.setOptions(name: "vm", baseline: baseline).arguments.contains("--disk-size"))

    let nonFinite = try #require(ConfigurationDraft(config: config(), listing: listing(diskGB: .infinity)))
    #expect(!nonFinite.isDiskCapacityKnown)
  }

  @Test func problemsRespectMinimums() throws {
    let config = try config()
    var draft = try #require(ConfigurationDraft(config: config, listing: listing(diskGB: 50)))
    #expect(draft.problems(config: config).isEmpty)
    draft.cpuCount = 2
    draft.memoryMB = 2048
    draft.width = 200
    draft.replacementDiskPath = "/nonexistent/\(UUID().uuidString).img"
    #expect(draft.problems(config: config).count == 4)
  }
}

@Suite("Log tail")
@MainActor
struct LogTailTests {
  private func temporaryLog() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-log-\(UUID()).log")
    try Data().write(to: url)
    return url
  }

  private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  @Test func followsAppendedOutput() throws {
    let url = try temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let tail = LogTail(url: url)
    tail.poll()
    #expect(tail.exists)
    #expect(tail.text.isEmpty)
    try append("booting\n", to: url)
    tail.poll()
    try append("ready\n", to: url)
    tail.poll()
    #expect(tail.text == "booting\nready\n")
  }

  @Test func startsOverWhenTruncatedOrRotated() throws {
    let url = try temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let tail = LogTail(url: url)
    try append("old line one\nold line two\n", to: url)
    tail.poll()
    // Truncate and write a shorter log, as a new launch would.
    try Data("new\n".utf8).write(to: url)
    tail.poll()
    #expect(tail.text == "new\n")
  }

  @Test func keepsOnlyTheNewestWindowFromALineStart() throws {
    let url = try temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let line = String(repeating: "x", count: 99) + "\n"
    try append(String(repeating: line, count: LogTail.window / 100 + 500), to: url)
    let tail = LogTail(url: url)
    tail.poll()
    #expect(tail.text.utf8.count <= LogTail.window)
    #expect(tail.text.hasPrefix("x"))
    #expect(tail.text.split(separator: "\n").allSatisfy { $0.count == 99 })
  }

  @Test func keepsTheFirstLineWhenTheWindowStartsAtALineBoundary() throws {
    let url = try temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    // A prefix whose last byte is a newline sits exactly before the window.
    let window = LogTail.window
    let firstLine = "first full line\n"
    let filler = String(repeating: "y", count: window - firstLine.utf8.count - 1) + "\n"
    try append("prefix\n" + firstLine + filler, to: url)
    let tail = LogTail(url: url)
    tail.poll()
    #expect(tail.text.hasPrefix(firstLine))
  }

  @Test func showsNothingUntilACutLineEnds() throws {
    let url = try temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    // One line longer than the window, still being written: the window starts mid-line.
    try append(String(repeating: "z", count: LogTail.window + 10), to: url)
    let tail = LogTail(url: url)
    tail.poll()
    #expect(tail.text.isEmpty)
    try append("z still the same line\nnext\n", to: url)
    tail.poll()
    #expect(tail.text == "next\n")
  }

  @Test func skipsWhatArrivedBeyondTheWindowBetweenPolls() throws {
    let url = try temporaryLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let tail = LogTail(url: url)
    try append("early\n", to: url)
    tail.poll()
    #expect(tail.text == "early\n")
    // 77-byte lines don't divide the window, so the window starts mid-line.
    let line = String(repeating: "w", count: 76) + "\n"
    try append(String(repeating: line, count: LogTail.window / 77 + 300) + "last\n", to: url)
    tail.poll()
    #expect(!tail.text.contains("early"), "older text no longer connects and is dropped")
    #expect(tail.text.hasPrefix("w"))
    #expect(tail.text.hasSuffix("last\n"))
    let lines = tail.text.split(separator: "\n")
    #expect(lines.dropLast().allSatisfy { $0.count == 76 }, "every kept line is complete")
    #expect(tail.text.utf8.count <= LogTail.window)
  }

  @Test func missingFileIsReported() {
    let tail = LogTail(url: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).log"))
    tail.poll()
    #expect(!tail.exists)
  }
}

@Suite("Console output")
@MainActor
struct ConsoleRunTests {
  @Test func trimsInBlocksWithStableIDs() {
    let run = ConsoleRun(command: "yes")
    let total = ConsoleRun.lineLimit + 1_234
    for index in 0..<total { run.append("line \(index)", isError: false) }

    #expect(run.lineCount <= ConsoleRun.lineLimit)
    #expect(run.lineCount > ConsoleRun.lineLimit - ConsoleRun.blockSize)
    #expect(run.droppedLineCount + run.lineCount == total)
    #expect(run.appendedLineCount == total)

    let ids = run.lines.map(\.id)
    #expect(ids == Array(ids.sorted()))
    #expect(Set(ids).count == ids.count)
    #expect(run.lines.last?.text == "line \(total - 1)")
    #expect(run.blocks.allSatisfy { $0.lines.count <= ConsoleRun.blockSize })
  }

  @Test func failureMessageIsNotRepeatedWhenAlreadyInAnEarlierBlock() {
    let run = ConsoleRun(command: "false")
    run.append("permission denied", isError: true)
    // Fill the rest of the block and start a new one after the message was streamed.
    for index in 0..<ConsoleRun.blockSize { run.append("line \(index)", isError: false) }
    #expect(run.blocks.count == 2)
    run.finish(1, message: "permission denied")
    #expect(run.lines.filter { $0.text == "permission denied" }.count == 1)
    #expect(run.exitCode == 1)
  }

  @Test func failureMessageIsAddedWhenNotPrinted() {
    let run = ConsoleRun(command: "false")
    run.append("some output", isError: false)
    run.finish(2, message: "VM is not running")
    #expect(run.lines.last?.text == "VM is not running")
  }

  @Test func transcriptIncludesTheCommand() {
    let run = ConsoleRun(command: "uname -a")
    run.append("Linux", isError: false)
    #expect(run.transcript == "$ uname -a\nLinux")
  }
}
