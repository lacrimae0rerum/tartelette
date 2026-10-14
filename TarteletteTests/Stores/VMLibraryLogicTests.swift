import Darwin
import Foundation
import Testing
import TarteletteKit

@testable import Tartelette

@Suite("VM library logic")
struct VMLibraryLogicTests {
  private func listing(_ name: String, _ state: VMState) -> VMListing {
    VMListing(name: name, source: .local, diskGB: 50, sizeGB: 1, lastAccessed: nil, state: state)
  }

  private func temporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-\(UUID()).log")
    try Data(contents.utf8).write(to: url)
    return url
  }

  // MARK: State changes

  @Test func detectsAppearedChangedAndRemovedVMs() {
    let old = [listing("a", .stopped), listing("b", .running), listing("same", .suspended)]
    let new = [listing("a", .running), listing("c", .stopped), listing("same", .suspended)]
    #expect(
      VMLibrary.stateChanges(from: old, to: new) == [
        VMStateChange(name: "a", oldState: .stopped, newState: .running),
        VMStateChange(name: "b", oldState: .running, newState: nil),
        VMStateChange(name: "c", oldState: nil, newState: .stopped),
      ])
  }

  @Test func firstListingReportsEveryVMAsNew() {
    let changes = VMLibrary.stateChanges(from: [], to: [listing("x", .running)])
    #expect(changes == [VMStateChange(name: "x", oldState: nil, newState: .running)])
    #expect(VMLibrary.stateChanges(from: [listing("x", .running)], to: [listing("x", .running)]).isEmpty)
  }

  // MARK: Quitting

  @Test func quittingAsksOnlyTheRunningVMsThisAppStarted() {
    let vms = [
      listing("mac", .running), listing("ubuntu", .running), listing("off", .stopped), listing("elsewhere", .running),
    ]
    #expect(VMLibrary.vmsToShutDownOnQuit(launched: ["ubuntu", "off", "mac", "gone"], vms: vms) == ["mac", "ubuntu"])
    #expect(VMLibrary.vmsToShutDownOnQuit(launched: [], vms: vms).isEmpty)
  }

  // MARK: Logs

  @Test func logTailReturnsTheLastLinesAfterAnOffset() throws {
    let file = try temporaryFile("one\ntwo\nthree\nfour\n")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(VMLibrary.logTail(file, lines: 2) == "three\nfour")
    #expect(VMLibrary.logTail(file, from: 8, lines: 10) == "three\nfour")
    #expect(VMLibrary.logTail(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())"), lines: 3) == "")
  }

  @Test func vncURLIsReadOnlyFromTheCurrentLaunch() throws {
    let earlier = "Opening vnc://192.168.64.2...\n"
    let file = try temporaryFile(earlier + "VNC server is running at vnc://:pass@127.0.0.1:5901\n")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(VMLibrary.vncURL(in: file, from: 0)?.absoluteString == "vnc://192.168.64.2")
    #expect(VMLibrary.vncURL(in: file, from: UInt64(earlier.utf8.count))?.absoluteString == "vnc://:pass@127.0.0.1:5901")
    #expect(VMLibrary.vncURL(in: file, from: UInt64(earlier.utf8.count + 200)) == nil)
  }

  @Test func launchHeaderMustMatchTheProcessStartTime() throws {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    try #require(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size)
    let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    let stamp = { (date: Date) in ISO8601DateFormatter().string(from: date) }

    let matching = try temporaryFile("old output\n=== \(stamp(started)) — tart run dev ===\nbooting\n")
    let stale = try temporaryFile("=== \(stamp(started.addingTimeInterval(-3_600))) — tart run dev ===\n")
    let garbage = try temporaryFile("=== not a date — tart run dev ===\n")
    let none = try temporaryFile("just output\n")
    defer { [matching, stale, garbage, none].forEach { try? FileManager.default.removeItem(at: $0) } }

    #expect(VMLibrary.logRecordsLaunch(of: getpid(), in: matching))
    #expect(!VMLibrary.logRecordsLaunch(of: getpid(), in: stale))
    #expect(!VMLibrary.logRecordsLaunch(of: getpid(), in: garbage))
    #expect(!VMLibrary.logRecordsLaunch(of: getpid(), in: none))
  }
}
