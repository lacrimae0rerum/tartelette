import AppKit
import SwiftUI
import TarteletteKit

/// Renders a clipboard payload: a text snippet, an image thumbnail or a file list.
struct ClipboardPreview: View {
  let payload: ClipboardPayload?
  var emptyTitle = "Empty"

  var body: some View {
    Group {
      if let payload, !payload.isEmpty {
        content(for: payload)
      } else {
        Text(emptyTitle)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 60)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func content(for payload: ClipboardPayload) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(payload.summary)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if !payload.files.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(payload.files.prefix(6), id: \.self) { file in
            Label {
              Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
            } icon: {
              Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 16, height: 16)
            }
          }
          if payload.files.count > 6 {
            Text("and \(payload.files.count - 6) more").font(.caption).foregroundStyle(.secondary)
          }
        }
      } else if let image = image(from: payload) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 120)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else if let text = payload.plainText {
        Text(text)
          .font(.callout)
          .lineLimit(5)
          .textSelection(.enabled)
      }
    }
  }

  private func image(from payload: ClipboardPayload) -> NSImage? {
    let data = payload.data(for: ClipboardRepresentation.png) ?? payload.data(for: ClipboardRepresentation.tiff)
    return data.flatMap(NSImage.init(data:))
  }
}
