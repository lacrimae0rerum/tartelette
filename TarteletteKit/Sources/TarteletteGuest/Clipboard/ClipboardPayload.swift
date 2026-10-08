import CryptoKit
import Foundation

/// One pasteboard flavour, identified by its UTI.
public struct ClipboardRepresentation: Sendable, Hashable, Codable {
  public static let plainText = "public.utf8-plain-text"
  public static let rtf = "public.rtf"
  public static let html = "public.html"
  public static let png = "public.png"
  public static let tiff = "public.tiff"

  /// Flavours the bridge transfers, in preference order.
  public static let supportedTypes = [plainText, rtf, html, png, tiff]

  public var type: String
  public var data: Data

  public init(type: String, data: Data) {
    self.type = type
    self.data = data
  }
}

/// A transport-neutral snapshot of a clipboard: flavoured data and/or files.
public struct ClipboardPayload: Sendable, Equatable {
  public let items: [ClipboardRepresentation]
  /// Host-local file URLs.
  public let files: [URL]
  /// Stable identity used to detect echoes: SHA-256 over sorted flavours and file names + sizes.
  public let fingerprint: String

  public init(items: [ClipboardRepresentation] = [], files: [URL] = []) {
    self.items = items
    self.files = files
    self.fingerprint = Self.fingerprint(items: items, files: files)
  }

  public var isEmpty: Bool { items.isEmpty && files.isEmpty }

  public var plainText: String? {
    items.first { $0.type == ClipboardRepresentation.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
  }

  public func data(for type: String) -> Data? {
    items.first { $0.type == type }?.data
  }

  public var totalByteCount: Int {
    items.reduce(0) { $0 + $1.data.count } + files.reduce(0) { $0 + Self.byteCount(of: $1) }
  }

  /// A one-line description such as "Text · 42 characters" or "3 files · 18 MB".
  public var summary: String {
    if !files.isEmpty {
      let size = ByteCountFormatter.string(fromByteCount: Int64(totalByteCount), countStyle: .file)
      if files.count == 1 { return "\(files[0].lastPathComponent) · \(size)" }
      return "\(files.count) files · \(size)"
    }
    if let image = items.first(where: { $0.type == ClipboardRepresentation.png || $0.type == ClipboardRepresentation.tiff }),
      plainText == nil
    {
      let format = image.type == ClipboardRepresentation.png ? "PNG" : "TIFF"
      return "Image · \(format) · \(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file))"
    }
    if let text = plainText {
      let count = text.count
      let rich = items.contains { $0.type == ClipboardRepresentation.rtf || $0.type == ClipboardRepresentation.html }
      return "\(rich ? "Rich text" : "Text") · \(count) character\(count == 1 ? "" : "s")"
    }
    if items.contains(where: { $0.type == ClipboardRepresentation.html }) { return "HTML" }
    if items.contains(where: { $0.type == ClipboardRepresentation.rtf }) { return "Rich text" }
    return "Empty"
  }

  static func fingerprint(items: [ClipboardRepresentation], files: [URL]) -> String {
    var hasher = SHA256()
    for item in items.sorted(by: { $0.type < $1.type }) {
      hasher.update(data: Data("type:\(item.type):\(item.data.count)\n".utf8))
      hasher.update(data: item.data)
    }
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      hasher.update(data: Data("file:\(file.lastPathComponent):\(byteCount(of: file))\n".utf8))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Size of a file, or the summed size of a directory tree.
  static func byteCount(of url: URL) -> Int {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
    guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
    if values.isDirectory != true { return values.fileSize ?? 0 }
    guard
      let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
    else { return 0 }
    var total = 0
    for case let child as URL in enumerator {
      total += (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
    return total
  }
}

enum Digest {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
