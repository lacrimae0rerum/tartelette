import Charts
import SwiftUI

/// A compact, axis-less area chart for live metrics.
struct Sparkline: View {
  let values: [Double]
  var tint: Color = .accentColor
  /// Fixes the top of the scale (e.g. 100 for percentages); nil scales to the data.
  var maxValue: Double?

  var body: some View {
    // Non-finite samples can't be plotted and would poison the scale (0...NaN traps).
    let plotted = values.filter(\.isFinite)
    Chart(Array(plotted.enumerated()), id: \.offset) { index, value in
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
    .chartYScale(domain: 0...Self.scaleTop(for: plotted, maxValue: maxValue))
    .chartXScale(domain: 0...max(plotted.count - 1, 1))
    .accessibilityHidden(true)
  }

  /// A finite, positive top for the y-scale, whatever the samples contain.
  static func scaleTop(for values: [Double], maxValue: Double?) -> Double {
    let peak = values.lazy.filter(\.isFinite).max()
    let top: Double =
      if let maxValue, maxValue.isFinite {
        max(maxValue, peak ?? 0)
      } else {
        (peak ?? 1) * 1.15
      }
    return top.isFinite && top > 0.0001 ? top : 1
  }
}
