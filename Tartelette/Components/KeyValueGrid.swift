import SwiftUI

/// A row in a `KeyValueGrid`. Rows are identified by their key (see `KeyValueGrid.identities`).
struct KeyValueRow {
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

  /// Stable identities derived from the keys, so SwiftUI keeps per-row state across re-renders.
  /// A repeated key gets its occurrence number appended (`Key`, `Key#2`, …).
  static func identities(for rows: [KeyValueRow]) -> [String] {
    var seen: [String: Int] = [:]
    return rows.map { row in
      let count = (seen[row.key] ?? 0) + 1
      seen[row.key] = count
      return count == 1 ? row.key : "\(row.key)#\(count)"
    }
  }

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
      ForEach(Array(zip(Self.identities(for: rows), rows)), id: \.0) { _, row in
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
