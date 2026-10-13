import Foundation
import TarteletteCore
import TarteletteGuest

/// How file content travels in `read_file` and `write_file`.
public enum AgentFileEncoding: String, Codable, Sendable {
  /// The bytes as UTF-8 text.
  case utf8
  /// The bytes in base64, for content that isn't valid UTF-8.
  case base64
}

/// Why a `read_file` or `write_file` call failed, phrased for a person reading the agent's transcript.
public enum AgentFileError: Error, Sendable, Equatable, LocalizedError {
  /// Not an absolute path of at most `AgentToolbox.maxGuestPathBytes` bytes without NUL characters.
  case invalidPath(String)
  case invalidOffset(Int)
  case notFound(path: String, vm: String)
  case isDirectory(path: String, vm: String)
  /// A device, socket or pipe, which can't be read as a file.
  case notRegularFile(path: String, vm: String)
  case offsetBeyondEnd(path: String, offset: Int, size: Int)
  /// `write_file` without `createDirectories` into a folder that doesn't exist.
  case directoryNotFound(path: String, vm: String)
  /// `write_file` content that isn't valid base64.
  case invalidBase64
  /// `write_file` content larger than the user's file size limit.
  case tooLarge(bytes: Int, limit: Int)
  /// A guest command of the file tools failed; `detail` is its message.
  case guestFailure(operation: String, path: String, vm: String, detail: String)

  public var errorDescription: String? {
    switch self {
    case .invalidPath(let path):
      "“\(path.prefix(80))” isn't a valid guest path. Paths are absolute (they start with “/”), have at most "
        + "\(AgentToolbox.maxGuestPathBytes) bytes and no NUL characters."
    case .invalidOffset(let offset):
      "The offset must be 0 or more, not \(offset)."
    case .notFound(let path, let vm):
      "There is no file at “\(path)” in “\(vm)”."
    case .isDirectory(let path, let vm):
      "“\(path)” in “\(vm)” is a directory, not a file. List it with exec (ls -la)."
    case .notRegularFile(let path, let vm):
      "“\(path)” in “\(vm)” isn't a regular file (it may be a device, socket or pipe)."
    case .offsetBeyondEnd(let path, let offset, let size):
      "Offset \(offset) is beyond the end of “\(path)”, which has \(size) bytes."
    case .directoryNotFound(let path, let vm):
      "The folder “\(path)” doesn't exist in “\(vm)”."
    case .invalidBase64:
      "The content isn't valid base64."
    case .tooLarge(let bytes, let limit):
      "The content has \(bytes) bytes, more than the \(limit) bytes agents may write at once. "
        + "The limit is set in Tartelette › Settings › Agents."
    case .guestFailure(let operation, let path, let vm, let detail):
      "Couldn't \(operation) “\(path)” in “\(vm)”: \(detail)"
    }
  }
}

extension AgentToolbox {
  /// The longest guest path, in UTF-8 bytes, the file tools accept.
  public static let maxGuestPathBytes = 1024

  /// Throws `invalidPath` unless `path` is absolute, at most `maxGuestPathBytes` bytes long and free
  /// of NUL characters. Relative and `~` paths are refused: the guest user's directory isn't
  /// something agents should have to guess.
  static func checkGuestPath(_ path: String) throws {
    guard path.hasPrefix("/"), path.utf8.count <= maxGuestPathBytes, !path.contains("\u{0}") else {
      throw AgentFileError.invalidPath(path)
    }
  }

  /// Runs one of the file tools' guest scripts and throws unless it succeeds.
  func runFileScript(_ command: [String], on guest: GuestEndpoint, operation: String, path: String)
    async throws -> CommandOutput
  {
    let output = try await guest.transport.run(command, standardInput: nil, timeout: .seconds(60))
    guard output.succeeded else {
      if let failure = Self.tartExecFailure(output, vm: guest.vmName) { throw failure }
      throw AgentFileError.guestFailure(operation: operation, path: path, vm: guest.vmName, detail: output.diagnostic)
    }
    return output
  }

  /// Runs a clipboard bridge transfer, reporting a guest agent that can't be reached like `exec` does.
  func transfer<Value>(_ guest: GuestEndpoint, _ body: () async throws -> Value) async throws -> Value {
    do {
      return try await body()
    } catch GuestTransportError.unreachable {
      throw AgentToolError.guestAgentUnreachable(guest.vmName)
    }
  }

  /// A bridge for the verified transfers only, which never use its host staging directory.
  static func bridge() -> ClipboardBridge {
    ClipboardBridge(fileStagingDirectory: FileManager.default.temporaryDirectory)
  }
}

/// Guest-side commands of the file tools, run as the clipboard bridge runs its own: through
/// `GuestScripts.userCommand`, so they act as the logged-in user, with paths passed as arguments
/// rather than spliced into the script.
enum AgentGuestScripts {
  static func shell(_ body: String, _ arguments: [String], os: VMOperatingSystem) -> [String] {
    GuestScripts.userCommand(["/bin/sh", "-c", body, "tartelette"] + arguments, os: os)
  }
}
