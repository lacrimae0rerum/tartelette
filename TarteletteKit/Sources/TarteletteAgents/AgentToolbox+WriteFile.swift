import CryptoKit
import Foundation
import TarteletteCore
import TarteletteGuest

/// What `write_file` reports.
public struct AgentWriteFileResult: Codable, Sendable, Equatable {
  public var path: String
  public var bytesWritten: Int
  /// SHA-256 of the bytes written, in lowercase hex; the guest's copy was checked against it.
  public var sha256: String

  public init(path: String, bytesWritten: Int, sha256: String) {
    self.path = path
    self.bytesWritten = bytesWritten
    self.sha256 = sha256
  }
}

extension AgentToolbox {
  /// `write_file` (writeFile): writes a file in a running VM, replacing any file already there.
  ///
  /// The bytes travel with the clipboard bridge's verified transfer (SHA-256, chunked when needed).
  ///
  /// - Parameters:
  ///   - path: An absolute guest path.
  ///   - content: The file's content, as text or base64 (see `encoding`).
  ///   - encoding: How `content` is encoded; base64 may contain line breaks.
  ///   - createDirectories: Create missing parent folders (the default).
  public func writeFile(
    name: String,
    path: String,
    content: String,
    encoding: AgentFileEncoding = .utf8,
    createDirectories: Bool = true
  ) async throws -> AgentWriteFileResult {
    try await perform(.writeFile, vm: name) { context in
      try authorize(.writeFile, vm: name, in: context)
      try Self.checkGuestPath(path)
      let data: Data
      switch encoding {
      case .utf8:
        data = Data(content.utf8)
      case .base64:
        guard let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }) else {
          throw AgentFileError.invalidBase64
        }
        data = decoded
      }
      let limit = context.policy.limits.maxFileBytes
      guard data.count <= limit else { throw AgentFileError.tooLarge(bytes: data.count, limit: limit) }
      let guest = try await runningGuest(name)
      let prepared = try await runFileScript(
        AgentGuestScripts.prepareWrite(path, createDirectories: createDirectories, os: guest.os), on: guest,
        operation: "write", path: path)
      let created: Bool
      switch prepared.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) {
      case "existing": created = false
      case "created": created = true
      case "directory": throw AgentFileError.isDirectory(path: path, vm: name)
      case "nofolder":
        throw AgentFileError.directoryNotFound(path: (path as NSString).deletingLastPathComponent, vm: name)
      default: throw GuestTransportError.unexpectedOutput(String(prepared.stdoutString.prefix(200)))
      }
      do {
        try await transfer(guest) { try await Self.bridge().upload(data, to: path, endpoint: guest) }
      } catch {
        // Don't leave behind a file this call created (best effort); an existing one stays.
        if created {
          _ = try? await guest.transport.run(
            AgentGuestScripts.removeFile(path, os: guest.os), standardInput: nil, timeout: .seconds(15))
        }
        throw error
      }
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return (AgentWriteFileResult(path: path, bytesWritten: data.count, sha256: digest), "\(path), \(data.count) bytes")
    }
  }
}

extension AgentGuestScripts {
  /// Prepares a guest path for writing. Once its folder exists (created when missing and
  /// `createDirectories`), prints `existing` for a file that was already there or `created` after
  /// creating it empty; prints `nofolder` when the folder is missing and may not be created, and
  /// `directory` when the path is a folder.
  ///
  /// The bridge's upload creates what is missing with `umask 077`, meant for its private staging
  /// files, so new files and folders are created here first with the guest user's own umask; the
  /// upload then rewrites the file in place, keeping its permissions.
  static func prepareWrite(_ path: String, createDirectories: Bool, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      f=$1; d=$(dirname "$f")
      [ -d "$f" ] && { echo directory; exit 0; }
      if [ ! -d "$d" ]; then
        [ "$2" = 1 ] || { echo nofolder; exit 0; }
        mkdir -p "$d" || exit 1
      fi
      if [ -e "$f" ]; then echo existing; else : > "$f" || exit 1; echo created; fi
      """#, [path, createDirectories ? "1" : "0"], os: os)
  }

  /// Removes a guest file; unlike `GuestScripts.remove`, never a folder.
  static func removeFile(_ path: String, os: VMOperatingSystem) -> [String] {
    shell(#"rm -f "$1""#, [path], os: os)
  }
}
