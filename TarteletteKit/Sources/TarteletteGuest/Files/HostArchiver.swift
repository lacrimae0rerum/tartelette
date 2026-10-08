import Foundation

/// Host-side `tar` helpers used to move files and folders through a single verified stream.
enum HostArchiver {
  static let tar = URL(fileURLWithPath: "/usr/bin/tar")

  /// Creates a gzip-compressed tarball of `files`, each stored under its last path component.
  ///
  /// - Throws: `GuestTransferError.duplicateNames` when two items share a name (one would
  ///   overwrite the other on extraction).
  static func archive(_ files: [URL], to archive: URL) async throws {
    try GuestTransferError.checkUniqueNames(files.map(\.lastPathComponent))
    var arguments = ["-czf", archive.path]
    for file in files {
      // `./name` keeps a name that starts with "-" from being read as a tar option.
      arguments += ["-C", file.deletingLastPathComponent().path, "./" + file.lastPathComponent]
    }
    // COPYFILE_DISABLE keeps macOS from adding AppleDouble `._*` entries for extended attributes.
    try await run(arguments, environment: ["COPYFILE_DISABLE": "1"])
  }

  /// Extracts a tarball into a fresh directory and returns its top-level entries (hidden ones
  /// included, so dotfiles aren't silently dropped), sorted.
  static func extract(_ archive: URL, into directory: URL) async throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try await run(["-xzf", archive.path, "-C", directory.path], environment: [:])
    let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
    return entries
      .filter { $0.lastPathComponent != "__MACOSX" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func run(_ arguments: [String], environment: [String: String]) async throws {
    let process = Process()
    process.executableURL = tar
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    // stderr goes to a file so a chatty tar can never fill a pipe and deadlock.
    let errorLog = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-tar-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: errorLog.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errorLog) }
    let errors = try FileHandle(forWritingTo: errorLog)
    defer { try? errors.close() }
    process.standardError = errors

    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    if status != 0 {
      let message = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
      throw GuestTransportError.commandFailed(status: status, message: "tar: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }
}
