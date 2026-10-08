import Darwin
import Foundation
import Testing

@testable import TarteletteMetrics

@Suite("Process inspection")
struct ProcessInspectorTests {
  @Test func convertsAppleSiliconTicksToNanoseconds() {
    #expect(ProcessInspector.nanoseconds(fromTicks: 24_000_000, numerator: 125, denominator: 3) == 1_000_000_000)
    #expect(ProcessInspector.nanoseconds(fromTicks: 1_234, numerator: 1, denominator: 1) == 1_234)
    // No overflow for large tick counts (≈ 40 days of CPU time).
    let ticks: UInt64 = 1 << 46
    #expect(ProcessInspector.nanoseconds(fromTicks: ticks, numerator: 125, denominator: 3) == ticks / 3 * 125 + (ticks % 3) * 125 / 3)
    #expect(ProcessInspector.nanoseconds(fromTicks: .max, numerator: 125, denominator: 3) == .max)
  }

  @Test func measuresOwnUsageAndCPUTimeGrows() throws {
    let before = try #require(ProcessInspector.usage(of: getpid()))
    #expect(before.pid == getpid())
    #expect(before.physicalFootprintBytes > 0)

    var accumulator: UInt64 = 0
    let deadline = ProcessInspector.monotonicNanoseconds() + 150_000_000
    while ProcessInspector.monotonicNanoseconds() < deadline { accumulator &+= UInt64.random(in: 0...9) }
    #expect(accumulator > 0)

    let after = try #require(ProcessInspector.usage(of: getpid()))
    #expect(after.cpuTimeNanoseconds > before.cpuTimeNanoseconds)
    #expect(after.capturedAtNanoseconds > before.capturedAtNanoseconds)
    // Converted CPU time can't exceed wall time by more than the core count.
    let cpu = Double(after.cpuTimeNanoseconds - before.cpuTimeNanoseconds)
    let wall = Double(after.capturedAtNanoseconds - before.capturedAtNanoseconds)
    #expect(cpu <= wall * Double(ProcessInfo.processInfo.activeProcessorCount) + 50_000_000)
  }

  @Test func listsOwnProcessAndPath() {
    #expect(ProcessInspector.allPIDs().contains(getpid()))
    #expect(ProcessInspector.executablePath(of: getpid())?.isEmpty == false)
    #expect(ProcessInspector.isAlive(getpid()))
    #expect(!ProcessInspector.isAlive(-1))
  }

  @Test func reportsOpenFiles() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-open-\(UUID()).bin")
    try Data(repeating: 1, count: 16).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }

    let expected = canonicalPath(file.path)
    #expect(ProcessInspector.openFilePaths(of: getpid()).map(canonicalPath).contains(expected))
  }

  @Test func findsChildProcesses() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["5"]
    try sleeper.run()
    defer { sleeper.terminate() }

    #expect(ProcessInspector.childPIDs(of: getpid()).contains(sleeper.processIdentifier))
  }
}
