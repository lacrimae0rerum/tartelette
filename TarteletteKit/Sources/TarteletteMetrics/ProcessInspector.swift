import Darwin
import Foundation
import TarteletteCore

/// Thin wrappers around libproc for inspecting host processes.
///
/// Every call is best effort: processes owned by other users or that exit mid-call yield `nil`
/// or empty results instead of errors.
public struct ProcessInspector: Sendable {
  /// `PROC_PIDPATHINFO_MAXSIZE` (4 × MAXPATHLEN), which Swift does not import.
  static let pathBufferSize = 4 * Int(MAXPATHLEN)

  /// The Mach timebase used to convert `rusage` CPU times (mach ticks on Apple Silicon).
  public static let timebase: (numerator: UInt32, denominator: UInt32) = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
    return (info.numer, info.denom)
  }()

  /// Converts mach absolute-time ticks to nanoseconds without intermediate overflow.
  public static func nanoseconds(fromTicks ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64 {
    guard numerator != denominator, denominator != 0 else { return ticks }
    let product = ticks.multipliedFullWidth(by: UInt64(numerator))
    let denominator = UInt64(denominator)
    // Saturate instead of trapping when the quotient would not fit in 64 bits.
    guard product.high < denominator else { return .max }
    return denominator.dividingFullWidth(product).quotient
  }

  /// Monotonic now in nanoseconds (CLOCK_UPTIME_RAW), the clock used for `ProcessUsage`.
  public static func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  }

  public static func allPIDs() -> [Int32] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = pids.withUnsafeMutableBytes { buffer in
      proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).filter { $0 > 0 }
  }

  public static func executablePath(of pid: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: pathBufferSize)
    let length = buffer.withUnsafeMutableBytes { raw in
      proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
    }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  public static func usage(of pid: Int32) -> ProcessUsage? {
    let capturedAt = monotonicNanoseconds()
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
      }
    }
    if status == 0 {
      return ProcessUsage(
        pid: pid,
        capturedAtNanoseconds: capturedAt,
        cpuTimeNanoseconds: cpuNanoseconds(user: info.ri_user_time, system: info.ri_system_time),
        physicalFootprintBytes: info.ri_phys_footprint,
        residentBytes: info.ri_resident_size,
        diskBytesRead: info.ri_diskio_bytesread,
        diskBytesWritten: info.ri_diskio_byteswritten,
        energyNanojoules: info.ri_energy_nj
      )
    }

    var fallback = rusage_info_v4()
    let fallbackStatus = withUnsafeMutablePointer(to: &fallback) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard fallbackStatus == 0 else { return nil }
    return ProcessUsage(
      pid: pid,
      capturedAtNanoseconds: capturedAt,
      cpuTimeNanoseconds: cpuNanoseconds(user: fallback.ri_user_time, system: fallback.ri_system_time),
      physicalFootprintBytes: fallback.ri_phys_footprint,
      residentBytes: fallback.ri_resident_size,
      diskBytesRead: fallback.ri_diskio_bytesread,
      diskBytesWritten: fallback.ri_diskio_byteswritten,
      energyNanojoules: nil
    )
  }

  /// Paths of the vnodes (files, devices, directories) the process has open.
  public static func openFilePaths(of pid: Int32) -> [String] {
    let bytesNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytesNeeded > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    // Leave headroom: the descriptor table can grow between the two calls.
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytesNeeded) / stride + 32)
    let bytesUsed = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytesUsed > 0 else { return [] }

    var paths: [String] = []
    let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    for descriptor in descriptors.prefix(Int(bytesUsed) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      let size = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize)
      guard size == infoSize else { continue }
      let path = withUnsafeBytes(of: info.pvip.vip_path) { raw -> String in
        let length = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw.prefix(length), as: UTF8.self)
      }
      if !path.isEmpty { paths.append(path) }
    }
    return paths
  }

  public static func childPIDs(of pid: Int32) -> [Int32] {
    let estimate = proc_listchildpids(pid, nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 16)
    let count = pids.withUnsafeMutableBytes { buffer in
      proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
    }
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).filter { $0 > 0 }
  }

  public static func isAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  /// When `pid` started, in microseconds since 1970 (`proc_bsdinfo.pbi_start_*`), or nil if the
  /// process is gone. Together with the pid it identifies one process instance.
  public static func startTime(of pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
  }

  private static func cpuNanoseconds(user: UInt64, system: UInt64) -> UInt64 {
    let (sum, overflow) = user.addingReportingOverflow(system)
    return nanoseconds(
      fromTicks: overflow ? .max : sum, numerator: timebase.numerator, denominator: timebase.denominator)
  }
}

/// Canonicalizes a path with realpath(3) so kernel-reported vnode paths (`/private/var/...`) and
/// user-facing paths (`/var/...`, a symlinked TART_HOME) compare equal.
func canonicalPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else {
    return (path as NSString).standardizingPath
  }
  defer { free(resolved) }
  return String(cString: resolved)
}
