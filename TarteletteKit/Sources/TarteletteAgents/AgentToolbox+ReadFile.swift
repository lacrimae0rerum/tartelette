import Foundation
import TarteletteCore
import TarteletteGuest

/// What `read_file` reports.
public struct AgentReadFileResult: Codable, Sendable, Equatable {
  public var path: String
  /// The bytes read, as text or base64 (see `encoding`).
  public var content: String
  public var encoding: AgentFileEncoding
  /// Where the bytes read start in the file.
  public var offset: Int
  /// How many bytes were read.
  public var length: Int
  /// The file's size in bytes.
  public var size: Int
  /// Whether the bytes read reach the end of the file.
  public var endOfFile: Bool

  public init(
    path: String,
    content: String,
    encoding: AgentFileEncoding,
    offset: Int,
    length: Int,
    size: Int,
    endOfFile: Bool
  ) {
    self.path = path
    self.content = content
    self.encoding = encoding
    self.offset = offset
    self.length = length
    self.size = size
    self.endOfFile = endOfFile
  }
}

extension AgentToolbox {
  /// `read_file` (readFile): reads part of a file in a running VM, so agents page through big files.
  ///
  /// The guest copies the requested range to a temporary file, which travels to the host with the
  /// clipboard bridge's verified transfer (SHA-256, chunked when needed) and is then removed.
  ///
  /// - Parameters:
  ///   - path: An absolute guest path.
  ///   - offset: The first byte to read (default 0).
  ///   - length: Bytes to read; defaults to, and is capped at, the user's output limit.
  public func readFile(name: String, path: String, offset: Int = 0, length: Int? = nil) async throws
    -> AgentReadFileResult
  {
    try await perform(.readFile, vm: name) { context in
      try authorize(.readFile, vm: name, in: context)
      try Self.checkGuestPath(path)
      guard offset >= 0 else { throw AgentFileError.invalidOffset(offset) }
      let limit = context.policy.limits.maxOutputBytes
      let count = length.map { $0 > 0 ? min($0, limit) : limit } ?? limit
      let guest = try await runningGuest(name)
      let output = try await runFileScript(
        AgentGuestScripts.stageRange(path, offset: offset, length: count, os: guest.os), on: guest, operation: "read",
        path: path)
      let fields = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
      let unexpected = GuestTransportError.unexpectedOutput(String(output.stdoutString.prefix(200)))
      let size: Int
      let staged: String?
      switch (fields.first, fields.count) {
      case ("file", 3):
        guard let reported = Int(fields[1]) else { throw unexpected }
        size = reported
        staged = fields[2] == "-" ? nil : String(fields[2])
      case ("missing", 1): throw AgentFileError.notFound(path: path, vm: name)
      case ("directory", 1): throw AgentFileError.isDirectory(path: path, vm: name)
      case ("special", 1): throw AgentFileError.notRegularFile(path: path, vm: name)
      case ("beyond", 2):
        guard let reported = Int(fields[1]) else { throw unexpected }
        throw AgentFileError.offsetBeyondEnd(path: path, offset: offset, size: reported)
      default:
        throw unexpected
      }
      var data = Data()
      if let staged { data = try await downloadStaged(staged, from: guest) }
      let page = Self.page(data, reachesEnd: offset + data.count >= size)
      let result = AgentReadFileResult(
        path: path, content: page.content, encoding: page.encoding, offset: offset, length: page.length, size: size,
        endOfFile: offset + page.length >= size)
      return (result, "\(path), bytes \(offset)..<\(offset + page.length) of \(size)")
    }
  }

  /// A page of a file as UTF-8 text when it is valid UTF-8, otherwise base64. A page that only
  /// fails because it ends inside a character, before the end of the file, is shortened to end
  /// before that character instead, so text files stay text page after page.
  static func page(_ data: Data, reachesEnd: Bool) -> (content: String, encoding: AgentFileEncoding, length: Int) {
    func text(_ bytes: Data) -> String? {
      let decoded = String(decoding: bytes, as: UTF8.self)
      return decoded.utf8.elementsEqual(bytes) ? decoded : nil
    }
    if let content = text(data) { return (content, .utf8, data.count) }
    if !reachesEnd {
      for cut in 1...3 where cut < data.count {
        if let content = text(data.dropLast(cut)) { return (content, .utf8, data.count - cut) }
      }
    }
    return (data.base64EncodedString(), .base64, data.count)
  }

  /// Downloads a guest temporary file with verification, then removes it (best effort, whether or
  /// not the download worked).
  private func downloadStaged(_ staged: String, from guest: GuestEndpoint) async throws -> Data {
    let result: Result<Data, any Error>
    do {
      result = .success(try await transfer(guest) { try await Self.bridge().download(staged, endpoint: guest) })
    } catch {
      result = .failure(error)
    }
    _ = try? await guest.transport.run(GuestScripts.remove([staged], os: guest.os), standardInput: nil, timeout: .seconds(15))
    return try result.get()
  }
}

extension AgentGuestScripts {
  /// Describes a guest path and copies up to `length` bytes of it, from `offset`, to a new
  /// temporary file. Prints `file <size> <temporary file>` (the temporary file is `-` when there
  /// is nothing to copy), `beyond <size>` when `offset` is past the end, or `missing`,
  /// `directory` or `special` for paths that aren't regular files.
  static func stageRange(_ path: String, offset: Int, length: Int, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      f=$1; o=$2; n=$3; t=-
      [ -e "$f" ] || { echo missing; exit 0; }
      [ -d "$f" ] && { echo directory; exit 0; }
      [ -f "$f" ] || { echo special; exit 0; }
      [ -r "$f" ] || { echo "Permission denied" >&2; exit 1; }
      s=$(wc -c < "$f" | tr -d ' ') || exit 1
      [ "$o" -le "$s" ] || { echo "beyond $s"; exit 0; }
      if [ "$o" -lt "$s" ]; then
        t=$(mktemp "${TMPDIR:-/tmp}/tartelette-read.XXXXXX") || exit 1
        tail -c +"$((o + 1))" "$f" | head -c "$n" > "$t" || { rm -f "$t"; exit 1; }
      fi
      printf 'file %s %s\n' "$s" "$t"
      """#, [path, String(offset), String(length)], os: os)
  }
}
