import Charts
import SwiftUI

/// One point of a time series.
struct ChartPoint: Identifiable, Hashable {
  var id: Date { date }
  let date: Date
  let value: Double
}

/// A named, coloured time series.
struct ChartSeries: Identifiable {
  var id: String { name }
  let name: String
  let color: Color
  let points: [ChartPoint]
}

/// A live time-series chart with a fixed time window, optional stacking, an optional limit rule
/// and a hover tooltip showing every series at the pointer.
struct TimeSeriesChart: View {
  let series: [ChartSeries]
  /// The visible window ends now and spans this many seconds.
  let window: TimeInterval
  var stacked = false
  /// Fixes the top of the y-axis (e.g. vCPUs × 100 or assigned memory); nil scales to the data.
  var yMax: Double?
  /// A dashed horizontal reference line, e.g. “4 vCPUs”.
  var rule: (value: Double, label: String)?
  var valueFormatter: (Double) -> String

  @State private var hoverDate: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      chart(now: context.date)
    }
  }

  private func chart(now: Date) -> some View {
    let start = now.addingTimeInterval(-window)
    let visible = series.map { item in
      // Non-finite values can't be plotted and would poison the y-scale.
      ChartSeries(
        name: item.name, color: item.color,
        points: item.points.filter { $0.date >= start && $0.value.isFinite })
    }

    return Chart {
      ForEach(visible) { item in
        ForEach(item.points) { point in
          if stacked {
            AreaMark(
              x: .value("Time", point.date),
              y: .value("Value", point.value),
              stacking: .standard
            )
            .foregroundStyle(by: .value("Series", item.name))
            .interpolationMethod(.monotone)
          } else {
            LineMark(
              x: .value("Time", point.date),
              y: .value("Value", point.value),
              series: .value("Series", item.name)
            )
            .foregroundStyle(by: .value("Series", item.name))
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
            if visible.count == 1 {
              AreaMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value)
              )
              .foregroundStyle(
                LinearGradient(
                  colors: [item.color.opacity(0.28), item.color.opacity(0.02)],
                  startPoint: .top, endPoint: .bottom)
              )
              .interpolationMethod(.monotone)
            }
          }
        }
      }

      if let rule, rule.value.isFinite {
        RuleMark(y: .value("Limit", rule.value))
          .foregroundStyle(.secondary.opacity(0.7))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .annotation(position: .top, alignment: .leading, spacing: 2) {
            Text(rule.label)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
      }

      if let hoverDate, hoverDate >= start {
        RuleMark(x: .value("Time", hoverDate))
          .foregroundStyle(.secondary.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(
            position: .top, spacing: 4,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            tooltip(at: hoverDate, in: visible)
          }
      }
    }
    .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
    .chartLegend(series.count > 1 ? .visible : .hidden)
    .chartLegend(position: .top, alignment: .trailing, spacing: 6)
    .chartXScale(domain: start...now)
    .chartYScale(domain: 0...yTop(visible))
    .chartXAxis {
      AxisMarks(values: .stride(by: axisStride.component, count: axisStride.count)) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        if let date = value.as(Date.self), now.timeIntervalSince(date) > window * 0.06 {
          AxisValueLabel(format: axisFormat, centered: false)
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine().foregroundStyle(.quaternary)
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(number == 0 ? "0" : valueFormatter(number))
          }
        }
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              guard let frame = proxy.plotFrame else { return }
              let x = location.x - geometry[frame].origin.x
              hoverDate = proxy.value(atX: x, as: Date.self)
            case .ended:
              hoverDate = nil
            }
          }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary(visible))
  }

  private func yTop(_ visible: [ChartSeries]) -> Double {
    let peak: Double =
      if stacked {
        stackedPeak(visible)
      } else {
        visible.flatMap(\.points).map(\.value).max() ?? 0
      }
    // Keep the reference line (and its label) inside the plot.
    let ruleTop = rule.map { $0.value * 1.12 }.flatMap { $0.isFinite ? $0 : nil } ?? 0
    let top =
      if let yMax, yMax.isFinite {
        max(yMax, peak, ruleTop, 0.0001)
      } else {
        max(peak * 1.2, ruleTop, 1)
      }
    // A domain of 0...NaN or 0...inf traps; fall back to a unit scale.
    return top.isFinite ? top : 1
  }

  /// Axis labels: seconds for short windows, minutes otherwise; marks stay clear of the edges.
  private var axisFormat: Date.FormatStyle {
    window <= 120 ? .dateTime.minute().second() : .dateTime.hour().minute()
  }

  private var axisStride: (component: Calendar.Component, count: Int) {
    switch window {
    case ...120: (.second, 15)
    case ...600: (.minute, 1)
    default: (.minute, 3)
    }
  }

  private func stackedPeak(_ visible: [ChartSeries]) -> Double {
    var totals: [Date: Double] = [:]
    for item in visible {
      for point in item.points { totals[point.date, default: 0] += point.value }
    }
    return totals.values.max() ?? 0
  }

  private func nearest(_ points: [ChartPoint], to date: Date) -> ChartPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
  }

  private func tooltip(at date: Date, in visible: [ChartSeries]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      let reference = visible.compactMap { nearest($0.points, to: date)?.date }.first ?? date
      Text(reference, format: .dateTime.hour().minute().second())
        .font(.caption2)
        .foregroundStyle(.secondary)
      ForEach(visible) { item in
        if let point = nearest(item.points, to: date) {
          HStack(spacing: 5) {
            Circle().fill(item.color).frame(width: 6, height: 6)
            if visible.count > 1 {
              Text(item.name).foregroundStyle(.secondary)
            }
            Text(valueFormatter(point.value))
              .monospacedDigit()
              .fontWeight(.semibold)
          }
          .font(.caption)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(.separator, lineWidth: 0.5)
    )
  }

  private func accessibilitySummary(_ visible: [ChartSeries]) -> String {
    visible.compactMap { item in
      item.points.last.map { "\(item.name) \(valueFormatter($0.value))" }
    }
    .joined(separator: ", ")
  }
}
