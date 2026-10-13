import Foundation
import Testing

@testable import TarteletteAgents

@Suite("Agent audit log")
struct AgentAuditLogTests {
  private static func entry(_ tool: String, detail: String? = nil, outcome: AgentAuditEntry.Outcome = .ok)
    -> AgentAuditEntry
  {
    AgentAuditEntry(
      date: Date(timeIntervalSince1970: 1_800_000_000), client: "test-client", tool: tool, vm: "dev",
      outcome: outcome, detail: detail)
  }

  private static func lines(of file: URL) throws -> [String] {
    try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  @Test func appendsOneJSONLinePerEntryCreatingTheDirectory() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let log = AgentAuditLog(file: directory.file("Logs/Tartelette/agents.log"))

    try log.record(Self.entry("exec", outcome: .failed))
    try log.record(Self.entry("delete_vm", outcome: .denied))

    let lines = try Self.lines(of: log.file)
    #expect(lines.count == 2)
    #expect(lines[0].contains(#""date":"2027-01-15T08:00:00Z""#))
    #expect(lines[0].contains(#""outcome":"failed""#))
    #expect(log.recent(limit: 10) == [Self.entry("exec", outcome: .failed), Self.entry("delete_vm", outcome: .denied)])
  }

  @Test func detailIsKeptOnOneLine() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let log = AgentAuditLog(file: directory.file("agents.log"))

    try log.record(Self.entry("exec", detail: "line one\nline two\r\nline three"))

    #expect(try Self.lines(of: log.file).count == 1)
    #expect(log.recent(limit: 1).first?.detail == "line one line two line three")
  }

  @Test func longDetailIsTruncated() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let log = AgentAuditLog(file: directory.file("agents.log"))

    try log.record(Self.entry("exec", detail: String(repeating: "x", count: 2_000)))

    let detail = try #require(log.recent(limit: 1).first?.detail)
    #expect(detail.count == 500)
    #expect(detail.hasSuffix("…"))
  }

  @Test func recentReturnsTheNewestEntriesOldestFirstSkippingMalformedLines() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let log = AgentAuditLog(file: directory.file("agents.log"))
    for index in 0..<5 { try log.record(Self.entry("tool-\(index)")) }
    let handle = try FileHandle(forWritingTo: log.file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("not json\n{\"tool\":\"partial\"}\n".utf8))
    try handle.close()
    try log.record(Self.entry("tool-5"))

    #expect(log.recent(limit: 3).map(\.tool) == ["tool-3", "tool-4", "tool-5"])
    #expect(log.recent(limit: 100).count == 6)
  }

  @Test func missingLogHasNoEntries() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    #expect(AgentAuditLog(file: directory.file("agents.log")).recent(limit: 10).isEmpty)
  }

  @Test func rotatesWhenTheLogExceedsTheThreshold() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let file = directory.file("agents.log")
    let rotated = directory.file("agents.log.1")
    let log = AgentAuditLog(file: file, rotationThreshold: 150)
    try Data("stale rotated log\n".utf8).write(to: rotated)

    try log.record(Self.entry("first"))
    try log.record(Self.entry("second"))
    #expect(try Self.lines(of: file).count == 2)

    // Over the threshold now: the next record moves the log aside first, replacing the old one.
    try log.record(Self.entry("third"))

    #expect(try Self.lines(of: file).count == 1)
    #expect(try Self.lines(of: rotated).count == 2)
    #expect(log.recent(limit: 10).map(\.tool) == ["first", "second", "third"])
  }

  @Test func defaultRotationThresholdIsFiveMebibytes() {
    #expect(AgentAuditLog.defaultRotationThreshold == 5 * 1024 * 1024)
  }
}
