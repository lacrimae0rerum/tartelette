import Darwin
import Foundation

/// Lists the executables running processes were started from.
///
/// The installer asks before deleting a version, so a running virtual machine never loses its binary.
public protocol RunningExecutablesProviding: Sendable {
  /// The executable path of every process this user can see, symbolic links resolved, such as
  /// `…/Tart/versions/2.41.0/tart.app/Contents/MacOS/tart`.
  func runningExecutablePaths() -> [String]
}

/// Lists running processes with `proc_listpids` and their executables with `proc_pidpath`.
public struct ProcessListRunningExecutables: RunningExecutablesProviding {
  public init() {}

  public func runningExecutablePaths() -> [String] {
    let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard size > 0 else { return [] }
    // Room for processes started between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 64)
    let filled = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return [] }
    return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }.compactMap(Self.executablePath)
  }

  /// `PROC_PIDPATHINFO_MAXSIZE` (4 × MAXPATHLEN), which Swift doesn't import.
  private static let pathBufferSize = 4 * Int(MAXPATHLEN)

  /// The executable of `pid`, or nil when the process is gone or belongs to someone else.
  private static func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: pathBufferSize)
    let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }
}
