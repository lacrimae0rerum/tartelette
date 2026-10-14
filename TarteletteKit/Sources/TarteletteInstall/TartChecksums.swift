import Foundation

/// The contents of a release's checksums file: one `<sha256>  <file name>` line per file.
public struct TartChecksums: Sendable {
  /// Lowercase hexadecimal SHA-256 by file name.
  private var digests: [String: String] = [:]

  /// Parses `sha256sum` output: 64 hexadecimal digits, a space, then the file name, optionally after a
  /// second space or the `*` binary marker. Blank lines are skipped; any other line that doesn't fit,
  /// or a file listed twice, throws `TartReleaseError.malformedChecksums`.
  public init(parsing text: String) throws {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (index, line) in lines.enumerated() where !line.allSatisfy(\.isWhitespace) {
      guard let (digest, fileName) = Self.entry(in: line), digests[fileName] == nil else {
        throw TartReleaseError.malformedChecksums(line: index + 1)
      }
      digests[fileName] = digest
    }
  }

  /// The SHA-256 the file named `fileName` must have, as 64 lowercase hexadecimal digits.
  /// Throws `TartReleaseError.missingChecksum` when the file isn't listed.
  public func expectedSHA256(for fileName: String) throws -> String {
    guard let digest = digests[fileName] else { throw TartReleaseError.missingChecksum(fileName: fileName) }
    return digest
  }

  private static func entry(in line: Substring) -> (digest: String, fileName: String)? {
    let digest = line.prefix(64)
    guard digest.count == 64, digest.utf8.allSatisfy(isHexDigit) else { return nil }

    var rest = line.dropFirst(64)
    guard rest.first == " " else { return nil }
    rest = rest.dropFirst()
    if rest.first == " " || rest.first == "*" { rest = rest.dropFirst() }
    guard !rest.isEmpty else { return nil }
    return (digest.lowercased(), String(rest))
  }

  private static func isHexDigit(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
      UInt8(ascii: "A")...UInt8(ascii: "F"):
      true
    default: false
    }
  }
}
