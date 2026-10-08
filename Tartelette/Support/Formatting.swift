import Foundation

/// Human-readable formatting shared by every screen. All functions are pure.
nonisolated enum Formatting {
  /// "1.2 GB", "512 MB" — decimal units, like Finder.
  static func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
  }

  static func bytes(_ value: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
  }

  /// Memory sizes use binary units, like Activity Monitor ("8 GB" for 8 GiB).
  static func memory(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
  }

  /// Tart reports VM disks in decimal gigabytes.
  static func gigabytes(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value < 1 { return value == 0 ? "0 GB" : "< 1 GB" }
    return value.formatted(.number.precision(.fractionLength(0...1))) + " GB"
  }

  /// Megabytes as configured in `tart set --memory` → "4 GB" / "1.5 GB".
  static func megabytes(_ value: UInt64) -> String {
    memory(value * 1024 * 1024)
  }

  /// "3.4 MB/s"
  static func rate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 KB/s" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
  }

  /// CPU where 100 = one core: "37%", "245%".
  static func cpu(_ percent: Double) -> String {
    guard percent.isFinite else { return "—" }
    return percent < 10
      ? percent.formatted(.number.precision(.fractionLength(1))) + "%"
      : percent.formatted(.number.precision(.fractionLength(0))) + "%"
  }

  /// 0...100 share: "42%".
  static func percent(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0))) + "%"
  }

  static func watts(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + " W"
  }

  /// "1:05:09", "4:12", "0:03".
  static func elapsed(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }

  /// "3 days", "5 hours" (for uptimes).
  static func duration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : (interval >= 3600 ? [.hour, .minute] : [.minute, .second])
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: interval) ?? "—"
  }

  /// "2 minutes ago".
  static func relative(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return "Never" }
    if abs(date.timeIntervalSince(now)) < 5 { return "Just now" }
    return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
  }

  static func loadAverage(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "—" }
    return values.prefix(3).map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  ")
  }
}
