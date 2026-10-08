import SwiftUI

/// A dashboard tile: icon, title, large value, caption and an optional sparkline.
struct MetricTile: View {
  let title: String
  let value: String
  var caption: String?
  var systemImage: String
  var tint: Color = .accentColor
  var series: [Double] = []
  var seriesMax: Double?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .monospacedDigit()
        .contentTransition(.numericText())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      if let caption {
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      // Tiles without a series keep the same height so grids stay aligned.
      Group {
        if series.isEmpty {
          Color.clear
        } else {
          Sparkline(values: series, tint: tint, maxValue: seriesMax)
        }
      }
      .frame(height: 34)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue([value, caption].compactMap { $0 }.joined(separator: ", "))
  }
}
