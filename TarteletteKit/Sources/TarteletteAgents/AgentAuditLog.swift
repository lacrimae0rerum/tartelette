import Foundation

/// One agent tool call, as recorded in the audit log.
public struct AgentAuditEntry: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable, Sendable {
    case ok
    /// Refused by the user's agent settings.
    case denied
    case failed
  }

  public var date: Date
  /// The agent client's name, when it reported one.
  public var client: String?
  public var tool: String
  public var vm: String?
  public var outcome: Outcome
  public var detail: String?

  public init(
    date: Date = Date(),
    client: String?,
    tool: String,
    vm: String? = nil,
    outcome: Outcome,
    detail: String? = nil
  ) {
    self.date = date
    self.client = client
    self.tool = tool
    self.vm = vm
    self.outcome = outcome
    self.detail = detail
  }
}

/// Append-only JSON Lines log of agent tool calls (`agents.log`), shared by concurrent processes.
///
/// Each entry is one `O_APPEND` write, so lines from different processes never interleave. When
/// the log exceeds the rotation threshold it is renamed to `agents.log.1` (replacing an older
/// one) before the next entry is written.
public struct AgentAuditLog: Sendable {
  public static let defaultRotationThreshold = 5 * 1024 * 1024
  public static let maxDetailLength = 500

  public let file: URL
  public let rotationThreshold: Int

  public init(file: URL, rotationThreshold: Int = AgentAuditLog.defaultRotationThreshold) {
    self.file = file
    self.rotationThreshold = rotationThreshold
  }

  /// The previous log, kept after rotation.
  public var rotatedFile: URL { file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".1") }

  /// Appends an entry, keeping its detail on one line and at most `maxDetailLength` characters.
  public func record(_ entry: AgentAuditEntry) throws {
    var entry = entry
    entry.detail = entry.detail.map(Self.sanitized)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(entry)
    line.append(UInt8(ascii: "\n"))

    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = try openForAppending()
    defer { close(descriptor) }
    // The lock serializes rotation: a process that waited for it sees that the file it opened was
    // already moved aside and appends to the new log instead of rotating again.
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw Self.posixError() }
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
    let isCurrent = isCurrentLog(info)
    if isCurrent && info.st_size <= rotationThreshold {
      return try Self.writeAll(line, to: descriptor)
    }
    if isCurrent {
      guard rename(file.path, rotatedFile.path) == 0 else { throw Self.posixError() }
    }
    // Rotated just now, or by another process while this one waited for the lock.
    try append(line)
  }

  /// Up to `limit` of the newest entries, oldest first, reading into the rotated log when the
  /// current one has fewer. Malformed lines are skipped.
  public func recent(limit: Int) -> [AgentAuditEntry] {
    guard limit > 0 else { return [] }
    var newestFirst = Self.newestEntries(in: file, limit: limit)
    if newestFirst.count < limit {
      newestFirst += Self.newestEntries(in: rotatedFile, limit: limit - newestFirst.count)
    }
    return newestFirst.reversed()
  }

  /// Newlines become spaces; longer details end in "…" at `maxDetailLength` characters.
  static func sanitized(_ detail: String) -> String {
    let singleLine = String(detail.map { $0.isNewline ? " " : $0 })
    guard singleLine.count > maxDetailLength else { return singleLine }
    return singleLine.prefix(maxDetailLength - 1) + "…"
  }

  private func openForAppending() throws -> Int32 {
    let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { throw Self.posixError() }
    return descriptor
  }

  /// Appends to a freshly opened log (after a rotation).
  private func append(_ line: Data) throws {
    let descriptor = try openForAppending()
    defer { close(descriptor) }
    try Self.writeAll(line, to: descriptor)
  }

  /// Whether an open descriptor's file is still the one at the log's path.
  private func isCurrentLog(_ info: stat) -> Bool {
    var current = stat()
    guard stat(file.path, &current) == 0 else { return false }
    return current.st_dev == info.st_dev && current.st_ino == info.st_ino
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written < 0 {
          guard errno == EINTR else { throw posixError() }
          continue
        }
        offset += written
      }
    }
  }

  private static func newestEntries(in file: URL, limit: Int) -> [AgentAuditEntry] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var entries: [AgentAuditEntry] = []
    for line in data.split(separator: UInt8(ascii: "\n")).reversed() where entries.count < limit {
      if let entry = try? decoder.decode(AgentAuditEntry.self, from: Data(line)) { entries.append(entry) }
    }
    return entries
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
