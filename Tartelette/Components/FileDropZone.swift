import SwiftUI
import UniformTypeIdentifiers

/// A dashed drop target for files and folders.
struct FileDropZone: View {
  let title: String
  var subtitle: String?
  var systemImage: String = "arrow.down.doc"
  var isEnabled = true
  let onDrop: ([URL]) -> Void

  @State private var isTargeted = false

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        .symbolEffect(.bounce, value: isTargeted)
      Text(title).font(.headline)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 120)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    )
    .opacity(isEnabled ? 1 : 0.5)
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard isEnabled, !files.isEmpty else { return false }
      onDrop(files)
      return true
    } isTargeted: { targeted in
      withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted && isEnabled }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Drop files here")
  }
}
