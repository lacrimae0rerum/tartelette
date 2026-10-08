import Charts
import SwiftUI

/// A compact, axis-less area chart for live metrics.
struct Sparkline: View {
  let values: [Double]
  var tint: Color = .accentColor
  /// Fixes the top of the scale (e.g. 100 for percentages); nil scales to the data.
  var maxValue: Double?

  var body: some View {
    Chart(Array(values.enumerated()), id: \.offset) { index, value in
      AreaMark(x: .value("Sample", index), y: .value("Value", value))
        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
        .interpolationMethod(.monotone)
      LineMark(x: .value("Sample", index), y: .value("Value", value))
        .foregroundStyle(tint)
        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .interpolationMethod(.monotone)
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartYScale(domain: 0...max(scaleTop, 0.0001))
    .chartXScale(domain: 0...max(values.count - 1, 1))
    .accessibilityHidden(true)
  }

  private var scaleTop: Double {
    if let maxValue { return max(maxValue, values.max() ?? 0) }
    return (values.max() ?? 1) * 1.15
  }
}
