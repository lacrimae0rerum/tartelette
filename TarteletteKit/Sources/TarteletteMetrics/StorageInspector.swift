import Foundation
import TarteletteCore

/// Measures the disk space Tart's storage actually occupies.
///
/// Sizes are allocated bytes, so sparse disk images count only the blocks they really use, and
/// symbolic links (OCI tags point at digest directories) are never followed or double-counted.
/// APFS clones are counted per file, as the filesystem does not expose shared extents.
public struct StorageInspector: Sendable {
  public init() {}

  public func usage(paths: TartPaths) async -> StorageUsage {
    await Task.detached(priority: .utility) {
      Self.measure(paths: paths)
    }.value
  }

  /// Allocated bytes of a file, or of everything below a directory.
  public func allocatedSize(of url: URL) async -> UInt64 {
    await Task.detached(priority: .utility) {
      Self.allocatedBytes(under: url)
    }.value
  }

  static func measure(paths: TartPaths) -> StorageUsage {
    let home = canonicalPath(paths.home.path)
    let buckets: [(prefix: String, keyPath: WritableKeyPath<Totals, UInt64>)] = [
      (canonicalPath(paths.vms.path) + "/", \.vms),
      (canonicalPath(paths.ociCache.path) + "/", \.oci),
      (canonicalPath(paths.ipswCache.path) + "/", \.ipsw),
    ]

    var totals = Totals()
    forEachRegularFile(under: URL(fileURLWithPath: home, isDirectory: true)) { path, bytes in
      let bucket = buckets.first { path.hasPrefix($0.prefix) }?.keyPath ?? \.other
      totals[keyPath: bucket] += bytes
    }

    let volume = volumeCapacity(near: paths.home)
    return StorageUsage(
      tartHome: paths.home,
      vmsBytes: totals.vms,
      ociCacheBytes: totals.oci,
      ipswCacheBytes: totals.ipsw,
      otherBytes: totals.other,
      volumeTotalBytes: volume.total,
      volumeAvailableBytes: volume.available
    )
  }

  static func allocatedBytes(under url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey]
    if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
      values.isSymbolicLink != true
    {
      return UInt64(values.totalFileAllocatedSize ?? 0)
    }
    var total: UInt64 = 0
    forEachRegularFile(under: url) { _, bytes in total += bytes }
    return total
  }

  private struct Totals {
    var vms: UInt64 = 0
    var oci: UInt64 = 0
    var ipsw: UInt64 = 0
    var other: UInt64 = 0
  }

  private static func forEachRegularFile(under directory: URL, _ body: (String, UInt64) -> Void) {
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
    else { return }

    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isSymbolicLink != true, values.isRegularFile == true
      else { continue }
      body(canonicalPath(url.path), UInt64(values.totalFileAllocatedSize ?? 0))
    }
  }

  private static func volumeCapacity(near url: URL) -> (total: UInt64, available: UInt64) {
    var candidate = url
    // TART_HOME may not exist yet; measure the closest existing ancestor's volume.
    while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
      candidate = candidate.deletingLastPathComponent()
    }
    let values = try? candidate.resourceValues(forKeys: [
      .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ])
    return (
      UInt64(max(0, values?.volumeTotalCapacity ?? 0)),
      UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
    )
  }
}
