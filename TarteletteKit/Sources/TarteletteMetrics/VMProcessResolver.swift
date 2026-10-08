import Foundation
import TarteletteCore
import os

/// Finds the host processes behind a running Tart VM.
///
/// The `tart run` PID is the holder of the VM's `config.json` lock. The guest itself runs in a
/// `com.apple.Virtualization.VirtualMachine` XPC service (parented to launchd), which is attributed
/// to the VM because it holds the VM's disk image or NVRAM open. Other Virtualization.framework
/// users (Docker, UTM, Lima) never match because their files live outside `$TART_HOME/vms/<name>/`.
///
/// All methods are synchronous and thread-safe. Results are cached per VM and the process table is
/// only re-scanned when the lock holder changes, a cached XPC process exits, or none was found yet.
public final class VMProcessResolver: Sendable {
  /// Executable name of Virtualization.framework's guest XPC service.
  public static let virtualMachineServiceName = "com.apple.Virtualization.VirtualMachine"
  /// Files inside a VM bundle that the XPC service keeps open while the guest runs.
  static let attributableFiles: Set<String> = ["disk.img", "nvram.bin", "overlay.asif"]

  private struct CacheEntry: Sendable {
    var tartPID: Int32
    var virtualMachinePIDs: [Int32]
  }

  private let paths: TartPaths
  private let table: any ProcessTable
  private let lockHolder: @Sendable (String) -> Int32?
  private let cache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])

  public convenience init(paths: TartPaths, table: any ProcessTable = SystemProcessTable()) {
    self.init(paths: paths, table: table, lockHolder: { name in VMLock.holderPID(vmNamed: name, paths: paths) })
  }

  init(paths: TartPaths, table: any ProcessTable, lockHolder: @escaping @Sendable (String) -> Int32?) {
    self.paths = paths
    self.table = table
    self.lockHolder = lockHolder
  }

  /// The processes of a running VM, or nil when nobody holds its lock (stopped or suspended).
  ///
  /// `virtualMachinePIDs` may be empty for a moment while the guest is still starting.
  public func processes(forVM name: String) -> VMProcessSet? {
    guard let tartPID = lockHolder(name) else {
      cache.withLock { $0[name] = nil }
      return nil
    }

    if let cached = cache.withLock({ $0[name] }), cached.tartPID == tartPID,
      !cached.virtualMachinePIDs.isEmpty,
      cached.virtualMachinePIDs.allSatisfy({ table.isAlive($0) })
    {
      return VMProcessSet(tartPID: tartPID, virtualMachinePIDs: cached.virtualMachinePIDs)
    }

    let virtualMachinePIDs = scanVirtualMachinePIDs(forVM: name)
    cache.withLock { $0[name] = CacheEntry(tartPID: tartPID, virtualMachinePIDs: virtualMachinePIDs) }
    return VMProcessSet(tartPID: tartPID, virtualMachinePIDs: virtualMachinePIDs)
  }

  /// Drops cached attributions so the next lookup re-scans the process table.
  public func invalidate() {
    cache.withLock { $0.removeAll() }
  }

  private func scanVirtualMachinePIDs(forVM name: String) -> [Int32] {
    let vmDirectory = canonicalPath(paths.vmDirectory(name).path)
    let prefix = vmDirectory.hasSuffix("/") ? vmDirectory : vmDirectory + "/"

    return table.allPIDs()
      .filter { pid in
        guard let path = table.executablePath(of: pid) else { return false }
        return (path as NSString).lastPathComponent == Self.virtualMachineServiceName
      }
      .filter { pid in
        table.openFilePaths(of: pid).contains { openPath in
          let resolved = canonicalPath(openPath)
          guard resolved.hasPrefix(prefix) else { return false }
          let relative = String(resolved.dropFirst(prefix.count))
          return Self.attributableFiles.contains(relative)
        }
      }
      .sorted()
  }
}
