import Foundation

/// A VM created by an agent.
public struct AgentVMEntry: Codable, Sendable, Hashable {
  public var name: String
  /// The VM or image it was cloned from.
  public var source: String
  /// The agent client that created it, when known.
  public var client: String?
  public var createdAt: Date
  /// `VMFingerprint` of the VM directory when it was created, so a VM later recreated under the
  /// same name isn't mistaken for this one.
  public var fingerprint: String

  public init(name: String, source: String, client: String?, createdAt: Date, fingerprint: String) {
    self.name = name
    self.source = source
    self.client = client
    self.createdAt = createdAt
    self.fingerprint = fingerprint
  }
}

/// The VMs created by agents (`agent-vms.json`), shared by concurrent helper processes.
///
/// Every read-modify-write holds an exclusive `flock` on the lock file and replaces the registry
/// file atomically, so plain reads always see a complete file and concurrent writers never lose
/// each other's changes.
public struct AgentVMRegistry: Sendable {
  public static let currentVersion = 1

  public let file: URL
  public let lockFile: URL

  public init(file: URL, lockFile: URL) {
    self.file = file
    self.lockFile = lockFile
  }

  public init(paths: AgentPaths) {
    self.init(file: paths.registryFile, lockFile: paths.registryLockFile)
  }

  /// The registered VMs in registration order; empty when there is no registry yet.
  ///
  /// - Throws: `AgentStoreError` when the file can't be read or decoded.
  public func entries() throws -> [AgentVMEntry] {
    guard let data = try AgentJSONFile.read(file) else { return [] }
    return try AgentJSONFile.decode(Contents.self, from: data, file: file).vms
  }

  /// Adds a VM, replacing an entry with the same name.
  public func register(_ entry: AgentVMEntry) throws {
    try update { entries in
      if let index = entries.firstIndex(where: { $0.name == entry.name }) {
        entries[index] = entry
      } else {
        entries.append(entry)
      }
    }
  }

  public func unregister(name: String) throws {
    try update { entries in entries.removeAll { $0.name == name } }
  }

  /// Drops entries for VMs that no longer exist.
  public func prune(keeping existingNames: Set<String>) throws {
    try update { entries in entries.removeAll { !existingNames.contains($0.name) } }
  }

  private struct Contents: Codable {
    var version: Int
    var vms: [AgentVMEntry]
  }

  /// Reads, transforms and writes the registry under the exclusive lock. Skips the write when
  /// nothing changed; a malformed registry throws instead of being overwritten.
  private func update(_ transform: (inout [AgentVMEntry]) -> Void) throws {
    try withExclusiveLock {
      let current = try entries()
      var updated = current
      transform(&updated)
      guard updated != current else { return }
      try AgentJSONFile.write(Contents(version: Self.currentVersion, vms: updated), to: file)
    }
  }

  /// Blocks until this process holds the exclusive `flock` on the lock file, then runs `body`.
  private func withExclusiveLock(_ body: () throws -> Void) throws {
    do {
      try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw AgentStoreError.unwritable(file: lockFile.lastPathComponent, detail: error.localizedDescription)
    }
    let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { throw Self.lockError(lockFile) }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw Self.lockError(lockFile) }
    }
    defer { flock(descriptor, LOCK_UN) }
    try body()
  }

  private static func lockError(_ file: URL) -> AgentStoreError {
    .unwritable(file: file.lastPathComponent, detail: String(cString: strerror(errno)))
  }
}
