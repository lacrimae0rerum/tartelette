import SwiftUI

/// A row in a `KeyValueGrid`.
struct KeyValueRow: Identifiable {
  let id = UUID()
  let key: String
  let value: String
  var monospaced = false
  /// Optional trailing accessory (e.g. a Reveal or Copy button).
  var accessory: AnyView?

  init(_ key: String, _ value: String, monospaced: Bool = false, accessory: AnyView? = nil) {
    self.key = key
    self.value = value
    self.monospaced = monospaced
    self.accessory = accessory
  }
}

/// Two aligned columns of labels and selectable values, like Finder's Get Info.
struct KeyValueGrid: View {
  let rows: [KeyValueRow]

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
      ForEach(rows) { row in
        GridRow {
          Text(row.key)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
          HStack(spacing: 6) {
            Text(row.value)
              .font(row.monospaced ? .system(.body, design: .monospaced) : .body)
              .textSelection(.enabled)
              .lineLimit(2)
              .truncationMode(.middle)
            if let accessory = row.accessory { accessory }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}
