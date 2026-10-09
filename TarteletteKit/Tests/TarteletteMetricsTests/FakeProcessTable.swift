import Foundation
import TarteletteCore
import os

@testable import TarteletteMetrics

/// A scripted process table: each `usage(of:)` call pops the next scripted snapshot for that pid.
final class FakeProcessTable: ProcessTable {
  struct Entry {
    var path: String
    var openFiles: [String] = []
    var children: [Int32] = []
    var usages: [ProcessUsage] = []
    /// Process start time (µs since 1970); a different value models a reused pid.
    var startTime: UInt64? = nil
  }

  private let state: OSAllocatedUnfairLock<[Int32: Entry]>

  init(_ entries: [Int32: Entry]) {
    state = OSAllocatedUnfairLock(initialState: entries)
  }

  func allPIDs() -> [Int32] { state.withLock { Array($0.keys).sorted() } }
  func executablePath(of pid: Int32) -> String? { state.withLock { $0[pid]?.path } }
  func openFilePaths(of pid: Int32) -> [String] { state.withLock { $0[pid]?.openFiles ?? [] } }
  func childPIDs(of pid: Int32) -> [Int32] { state.withLock { $0[pid]?.children ?? [] } }

  func usage(of pid: Int32) -> ProcessUsage? {
    state.withLock { entries in
      guard var entry = entries[pid], !entry.usages.isEmpty else { return nil }
      let next = entry.usages.removeFirst()
      entries[pid] = entry
      return next
    }
  }

  func startTime(of pid: Int32) -> UInt64? { state.withLock { $0[pid]?.startTime } }

  func remove(_ pid: Int32) {
    state.withLock { _ = $0.removeValue(forKey: pid) }
  }

  /// Replaces whatever runs as `pid` (models the kernel reusing a pid for a new process).
  func replace(_ pid: Int32, with entry: Entry) {
    state.withLock { $0[pid] = entry }
  }
}

let virtualizationServicePath =
  "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
  + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

func usage(
  _ pid: Int32, atSeconds seconds: Double, cpuSeconds: Double, footprint: UInt64 = 0, read: UInt64 = 0,
  written: UInt64 = 0, energyJoules: Double? = nil
) -> ProcessUsage {
  ProcessUsage(
    pid: pid,
    capturedAtNanoseconds: UInt64(seconds * 1e9),
    cpuTimeNanoseconds: UInt64(cpuSeconds * 1e9),
    physicalFootprintBytes: footprint,
    residentBytes: footprint,
    diskBytesRead: read,
    diskBytesWritten: written,
    energyNanojoules: energyJoules.map { UInt64($0 * 1e9) }
  )
}

/// A temporary TART_HOME with `vms/<name>/{config.json,disk.img,nvram.bin}` for each VM.
struct TemporaryTartHome {
  let paths: TartPaths

  init(vms: [String]) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-home-\(UUID())")
    paths = TartPaths(home: home)
    for name in vms {
      let directory = paths.vmDirectory(name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: paths.configFile(name))
      try Data().write(to: paths.diskImage(name))
      try Data().write(to: paths.nvram(name))
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: paths.home)
  }
}
