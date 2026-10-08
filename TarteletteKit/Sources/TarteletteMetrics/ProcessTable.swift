import Foundation
import TarteletteCore

/// Read access to the host's process table, abstracted so attribution and rate math are testable.
public protocol ProcessTable: Sendable {
  func allPIDs() -> [Int32]
  func executablePath(of pid: Int32) -> String?
  func openFilePaths(of pid: Int32) -> [String]
  func childPIDs(of pid: Int32) -> [Int32]
  func usage(of pid: Int32) -> ProcessUsage?
  func isAlive(_ pid: Int32) -> Bool
}

extension ProcessTable {
  public func isAlive(_ pid: Int32) -> Bool { executablePath(of: pid) != nil }
}

/// The live process table backed by libproc.
public struct SystemProcessTable: ProcessTable {
  public init() {}

  public func allPIDs() -> [Int32] { ProcessInspector.allPIDs() }
  public func executablePath(of pid: Int32) -> String? { ProcessInspector.executablePath(of: pid) }
  public func openFilePaths(of pid: Int32) -> [String] { ProcessInspector.openFilePaths(of: pid) }
  public func childPIDs(of pid: Int32) -> [Int32] { ProcessInspector.childPIDs(of: pid) }
  public func usage(of pid: Int32) -> ProcessUsage? { ProcessInspector.usage(of: pid) }
  public func isAlive(_ pid: Int32) -> Bool { ProcessInspector.isAlive(pid) }
}
