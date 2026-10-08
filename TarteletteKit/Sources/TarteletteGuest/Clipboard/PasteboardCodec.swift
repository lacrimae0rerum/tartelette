import AppKit
import Foundation

/// Converts between `NSPasteboard` contents and `ClipboardPayload`.
@MainActor
public enum PasteboardCodec {
  /// Captures the transferable contents of a pasteboard, or nil when it holds nothing supported.
  ///
  /// File URLs win over other flavours (Finder also adds icons and names, which aren't useful
  /// remotely). TIFF-only images are converted to PNG, which is far smaller to transfer.
  public static func snapshot(_ pasteboard: NSPasteboard = .general) -> ClipboardPayload? {
    let fileURLs = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]) ?? []
    let existingFiles = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    if !existingFiles.isEmpty { return ClipboardPayload(files: existingFiles) }

    guard let item = pasteboard.pasteboardItems?.first else { return nil }
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
    writers += payload.files.map { $0 as NSURL }
    if !writers.isEmpty { pasteboard.writeObjects(writers) }
    return pasteboard.changeCount
  }
}
