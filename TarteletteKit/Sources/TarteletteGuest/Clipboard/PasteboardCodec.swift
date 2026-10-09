import AppKit
import Foundation

/// Converts between `NSPasteboard` contents and `ClipboardPayload`.
@MainActor
public enum PasteboardCodec {
  /// A cheap signature of what the pasteboard holds right now: every item's types, the size of
  /// each flavour the bridge moves, and file URLs. Contents aren't hashed.
  ///
  /// Writers clear a pasteboard (which bumps `changeCount`) and then add items (which doesn't), so
  /// the change count alone can't tell a finished write from one in progress; two equal shapes a
  /// poll apart can. An empty pasteboard has an empty shape.
  public static func shape(_ pasteboard: NSPasteboard = .general) -> String {
    guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return "" }
    return items.map { item in
      item.types.map { type -> String in
        if type == .fileURL { return "file=" + (item.string(forType: .fileURL) ?? "") }
        if ClipboardRepresentation.supportedTypes.contains(type.rawValue) {
          return "\(type.rawValue)=\(item.data(forType: type)?.count ?? -1)"
        }
        return type.rawValue
      }.joined(separator: ",")
    }.joined(separator: "|")
  }

  /// The result of reading a pasteboard.
  public enum Capture: Equatable, Sendable {
    /// Everything the pasteboard holds was read; nil when it holds nothing supported.
    case complete(ClipboardPayload?)
    /// Some item hasn't been handed over by its writer yet; read again later.
    case incomplete
  }

  /// Reads the transferable contents of a pasteboard.
  ///
  /// File URLs win over other flavours (Finder also adds icons and names, which aren't useful
  /// remotely). Every item declaring a file URL must resolve: writers hand items to the pasteboard
  /// server lazily, and an item that hasn't arrived yet would otherwise be silently left out, so
  /// a partial copy would be synced. TIFF-only images are converted to PNG, which is far smaller
  /// to transfer.
  public static func capture(_ pasteboard: NSPasteboard = .general) -> Capture {
    let items = pasteboard.pasteboardItems ?? []
    var fileURLs: [URL] = []
    var declaresFileURLs = false
    for item in items where item.types.contains(.fileURL) {
      declaresFileURLs = true
      guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else {
        return .incomplete
      }
      // File reference URLs (file:///.file/id=…) resolve to a path URL.
      fileURLs.append((url as NSURL).filePathURL ?? url)
    }
    if !declaresFileURLs {
      // Writers using legacy flavours (e.g. NSFilenamesPboardType) only surface through URL reading.
      fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    let existingFiles = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    if !existingFiles.isEmpty { return .complete(ClipboardPayload(files: existingFiles)) }
    return .complete(flavours(of: items.first))
  }

  /// The transferable contents of a pasteboard, or nil when it holds nothing supported or some
  /// item hasn't been handed over yet (see `capture(_:)`).
  public static func snapshot(_ pasteboard: NSPasteboard = .general) -> ClipboardPayload? {
    if case .complete(let payload) = capture(pasteboard) { payload } else { nil }
  }

  private static func flavours(of item: NSPasteboardItem?) -> ClipboardPayload? {
    guard let item else { return nil }
    let declared = Set(item.types.map(\.rawValue))
    var items: [ClipboardRepresentation] = []
    for type in ClipboardRepresentation.supportedTypes where declared.contains(type) {
      guard let data = item.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty else { continue }
      items.append(ClipboardRepresentation(type: type, data: data))
    }

    let hasPNG = items.contains { $0.type == ClipboardRepresentation.png }
    if !hasPNG, let tiffIndex = items.firstIndex(where: { $0.type == ClipboardRepresentation.tiff }),
      let png = NSBitmapImageRep(data: items[tiffIndex].data)?.representation(using: .png, properties: [:])
    {
      items[tiffIndex] = ClipboardRepresentation(type: ClipboardRepresentation.png, data: png)
    }

    return items.isEmpty ? nil : ClipboardPayload(items: items)
  }

  /// Replaces the pasteboard contents with a payload and returns the new change count.
  ///
  /// All flavours go on one pasteboard item (so apps pick their richest supported flavour); each
  /// file becomes its own item, as Finder does.
  @discardableResult
  public static func write(_ payload: ClipboardPayload, to pasteboard: NSPasteboard = .general) -> Int {
    pasteboard.clearContents()
    var writers: [any NSPasteboardWriting] = []
    if !payload.items.isEmpty {
      let item = NSPasteboardItem()
      for representation in payload.items {
        item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
      }
      writers.append(item)
    }
    for file in payload.files {
      // One item per file, as Finder writes them, with the URL set up front rather than promised:
      // `NSURL` writers hand later items to the pasteboard server on demand, so the content
      // other apps (and our own polling) see would keep changing after the write.
      let item = NSPasteboardItem()
      item.setString(file.absoluteString, forType: .fileURL)
      writers.append(item)
    }
    if !writers.isEmpty { pasteboard.writeObjects(writers) }
    settle(pasteboard)
    return pasteboard.changeCount
  }

  /// Makes the pasteboard server take every item now by reading each flavour back, so the written
  /// content is complete and stable as soon as `write` returns.
  static func settle(_ pasteboard: NSPasteboard) {
    for item in pasteboard.pasteboardItems ?? [] {
      for type in item.types { _ = item.data(forType: type) }
    }
  }
}
