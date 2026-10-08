import SwiftUI

/// One coloured segment of a `MeterBar`.
struct MeterSegment: Identifiable, Hashable {
  var id: String { label }
  let label: String
  let value: Double
  let color: Color
}

/// A segmented capacity bar (like “About This Mac › Storage”) with an optional legend.
struct MeterBar: View {
  let segments: [MeterSegment]
  /// The full capacity; the remainder is drawn as an empty track.
  let total: Double
  var height: CGFloat = 14
  var showsLegend = true
  var formatter: (Double) -> String = { Formatting.bytes(UInt64(max(0, $0))) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { proxy in
        HStack(spacing: 1.5) {
          ForEach(visibleSegments) { segment in
            Rectangle()
              .fill(segment.color.gradient)
              .frame(width: max(2, proxy.size.width * fraction(segment.value)))
              .help("\(segment.label): \(formatter(segment.value))")
          }
          Spacer(minLength: 0)
        }
        .frame(width: proxy.size.width, height: height, alignment: .leading)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
      }
      .frame(height: height)

      if showsLegend {
        FlowingLegend(segments: segments, formatter: formatter)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(segments.map { "\($0.label) \(formatter($0.value))" }.joined(separator: ", "))
  }

  private var visibleSegments: [MeterSegment] { segments.filter { $0.value > 0 } }

  private func fraction(_ value: Double) -> CGFloat {
    guard total > 0 else { return 0 }
    return CGFloat(min(1, value / total))
  }
}

private struct FlowingLegend: View {
  let segments: [MeterSegment]
  let formatter: (Double) -> String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) { items }
      VStack(alignment: .leading, spacing: 4) { items }
    }
  }

  @ViewBuilder private var items: some View {
    ForEach(segments.filter { $0.value > 0 }) { segment in
      HStack(spacing: 5) {
        Circle().fill(segment.color).frame(width: 8, height: 8)
        Text(segment.label).foregroundStyle(.secondary)
        Text(formatter(segment.value)).monospacedDigit()
      }
      .font(.caption)
    }
  }
}
