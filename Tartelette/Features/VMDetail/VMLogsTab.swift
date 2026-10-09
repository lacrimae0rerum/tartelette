import AppKit
import Observation
import SwiftUI

/// Follows a growing text file: reads the tail once, then appends new bytes as they arrive.
@Observable
final class LogTail {
  private(set) var text = ""
  private(set) var exists = false
  private(set) var size: UInt64 = 0

  private let url: URL
  private var offset: UInt64 = 0
  private var task: Task<Void, Never>?

  /// Only this much of a long log is loaded and kept on screen.
  static let window = 256 * 1024

  init(url: URL) {
    self.url = url
  }

  isolated deinit {
    task?.cancel()
  }

  func start() {
    task?.cancel()
    task = Task { [weak self] in
      while !Task.isCancelled {
        do {
          // Hold the tail only while polling, so it can be released between polls.
          guard let self else { return }
          self.poll()
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  /// Reads whatever was appended since the last poll (internal for tests).
  func poll() {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      exists = false
      return
    }
    defer { try? handle.close() }
    exists = true
    let end = (try? handle.seekToEnd()) ?? 0
    size = end
    if end < offset {
      // Rotated or truncated.
      offset = 0
      text = ""
    }
    guard end > offset else { return }
    let windowStart = end > UInt64(Self.window) ? end - UInt64(Self.window) : 0
    // More than a window arrived since the last read (or this is the first read of a long log):
    // the bytes in between are skipped, so the old text no longer connects to the new chunk.
    let skipped = windowStart > offset
    try? handle.seek(toOffset: max(offset, windowStart))
    let data = (try? handle.readToEnd()) ?? Data()
    offset = end
    var chunk = String(decoding: data, as: UTF8.self)
    if skipped {
      // Start at the next full line rather than mid-line.
      if let newline = chunk.firstIndex(of: "\n") { chunk = String(chunk[chunk.index(after: newline)...]) }
      text = ""
    }
    text += chunk
    if text.utf8.count > Self.window {
      let excess = text.utf8.count - Self.window
      let cut = text.utf8.index(text.utf8.startIndex, offsetBy: excess)
      let lineStart = text[cut...].firstIndex(of: "\n").map { text.index(after: $0) } ?? cut
      text = String(text[lineStart...])
    }
  }
}

/// The live output of `tart run` for this VM (`~/Library/Logs/Tartelette/<name>.log`).
struct VMLogsTab: View {
  let vmName: String
  @Environment(AppModel.self) private var model
  @State private var tail: LogTail?
  @State private var followsOutput = true

  var body: some View {
    let url = model.library.logFile(for: vmName)

    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text((url.path as NSString).abbreviatingWithTildeInPath)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        if let tail, tail.exists {
          Text(Formatting.bytes(tail.size))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Toggle("Follow", isOn: $followsOutput)
          .toggleStyle(.checkbox)
          .help("Keep the newest output in view")
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(tail?.text ?? "", forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(tail?.text.isEmpty ?? true)
        Button {
          model.library.revealLog(vmName)
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      Divider()

      if let tail, tail.exists, !tail.text.isEmpty {
        LogTextView(text: tail.text, followsOutput: followsOutput)
      } else {
        EmptyStateView(
          "No Log Yet", systemImage: "doc.text.magnifyingglass",
          message: model.library.isRunning(vmName) && !model.library.wasStartedByTartelette(vmName)
            ? "This VM was started outside Tartelette, so its output goes elsewhere."
            : "Tart's output appears here when Tartelette starts this VM.")
      }
    }
    .onAppear {
      let tail = LogTail(url: url)
      self.tail = tail
      tail.start()
    }
    .onDisappear { tail?.stop() }
  }
}

/// A read-only, selectable monospaced text view that can keep its end in view.
private struct LogTextView: View {
  let text: String
  let followsOutput: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
          Color.clear.frame(height: 1).id("end")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .onAppear { proxy.scrollTo("end", anchor: .bottom) }
      .onChange(of: text) {
        if followsOutput { proxy.scrollTo("end", anchor: .bottom) }
      }
    }
  }
}
