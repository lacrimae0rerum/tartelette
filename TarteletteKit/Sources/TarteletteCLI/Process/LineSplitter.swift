import Foundation
import TarteletteCore

/// Splits a byte stream into text lines, tolerating partial lines and carriage-return redraws.
struct LineSplitter: Sendable {
  private var buffer = Data()

  /// Appends bytes and returns every line completed by them (without terminators).
  mutating func append(_ data: Data) -> [String] {
    buffer.append(data)
    var lines: [String] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      lines.append(Self.render(buffer[buffer.startIndex..<newline]))
      buffer.removeSubrange(buffer.startIndex...newline)
    }
    return lines
  }

  /// Returns the trailing partial line, if any, and resets the buffer.
  mutating func flush() -> [String] {
    defer { buffer.removeAll() }
    return buffer.isEmpty ? [] : [Self.render(buffer)]
  }

  /// Decodes one line with terminal semantics: a carriage return redraws the line, so the last
  /// non-empty segment wins, and ANSI escape sequences are removed.
  static func render(_ bytes: Data) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    let segments = text.split(separator: "\r", omittingEmptySubsequences: false)
      .map { TartProgressParser.stripANSI(String($0)) }
    let visible = segments.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    return visible.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
