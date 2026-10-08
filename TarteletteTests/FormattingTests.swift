import Foundation
import Testing

@testable import Tartelette

/// Formatting drives every number on screen, so its boundaries are pinned here. Expectations are
/// built with the current locale's decimal separator, so the suite passes in any locale.
@Suite("Formatting")
struct FormattingTests {
  private let separator = Locale.current.decimalSeparator ?? "."

  private func decimal(_ text: String) -> String {
    text.replacingOccurrences(of: ".", with: separator)
  }

  @Test func gigabytesBoundaries() {
    #expect(Formatting.gigabytes(nil) == "—")
    #expect(Formatting.gigabytes(0) == "0 GB")
    #expect(Formatting.gigabytes(-3) == "0 GB")
    #expect(Formatting.gigabytes(0.4) == "< 1 GB")
    #expect(Formatting.gigabytes(1) == "1 GB")
    #expect(Formatting.gigabytes(20.25) == decimal("20.2 GB") || Formatting.gigabytes(20.25) == decimal("20.3 GB"))
    #expect(Formatting.gigabytes(.nan) == "—")
    #expect(Formatting.gigabytes(.infinity) == "—")
  }

  @Test func cpuSwitchesPrecisionAtTenPercent() {
    #expect(Formatting.cpu(0) == decimal("0.0%"))
    #expect(Formatting.cpu(9.94) == decimal("9.9%"))
    #expect(Formatting.cpu(10) == "10%")
    #expect(Formatting.cpu(245.4) == "245%")
    #expect(Formatting.cpu(.nan) == "—")
    #expect(Formatting.cpu(-.infinity) == "—")
  }

  @Test func elapsedRoundsAndRollsOverToHours() {
    #expect(Formatting.elapsed(0) == "0:00")
    #expect(Formatting.elapsed(2.6) == "0:03")
    #expect(Formatting.elapsed(59.5) == "1:00")
    #expect(Formatting.elapsed(3_599.4) == "59:59")
    #expect(Formatting.elapsed(3_599.6) == "1:00:00")
    #expect(Formatting.elapsed(3_909) == "1:05:09")
    #expect(Formatting.elapsed(-5) == "0:00")
    #expect(Formatting.elapsed(.nan) == "0:00")
    #expect(Formatting.elapsed(.infinity) == "0:00")
    #expect(!Formatting.elapsed(1e300).isEmpty)
  }

  @Test func rateHandlesZeroAndNonFiniteInput() {
    #expect(Formatting.rate(0) == "0 KB/s")
    #expect(Formatting.rate(-1) == "0 KB/s")
    #expect(Formatting.rate(.nan) == "0 KB/s")
    #expect(Formatting.rate(.infinity) == "0 KB/s")
    #expect(Formatting.rate(2_000_000).hasSuffix("/s"))
    // Values beyond Int64 saturate instead of trapping.
    #expect(Formatting.rate(1e30).hasSuffix("/s"))
  }

  @Test func wattsPrecision() {
    #expect(Formatting.watts(nil) == "—")
    #expect(Formatting.watts(.nan) == "—")
    #expect(Formatting.watts(0) == decimal("0.0 W"))
    #expect(Formatting.watts(5.56) == decimal("5.6 W"))
    #expect(Formatting.watts(12.4) == "12 W")
  }

  @Test func megabytesNeverOverflow() {
    #expect(Formatting.megabytes(4_096) == Formatting.memory(4_096 * 1024 * 1024))
    #expect(Formatting.megabytes(.max) == Formatting.memory(.max))
    #expect(Formatting.megabytes(UInt64.max / (1024 * 1024) + 1) == Formatting.memory(.max))
  }

  @Test func clampedInt64Saturates() {
    #expect(Formatting.clampedInt64(42.9) == 42)
    #expect(Formatting.clampedInt64(.nan) == 0)
    #expect(Formatting.clampedInt64(1e300) == .max)
    #expect(Formatting.clampedInt64(-1e300) == .min)
    #expect(Formatting.clampedInt64(9_223_372_036_854_775_808.0) == .max)
  }

  @Test func sparklineScaleIsAlwaysFinite() {
    #expect(Sparkline.scaleTop(for: [], maxValue: nil) == 1.15)
    #expect(Sparkline.scaleTop(for: [.nan, .infinity], maxValue: nil) == 1.15)
    #expect(Sparkline.scaleTop(for: [.nan, 50], maxValue: 100) == 100)
    #expect(Sparkline.scaleTop(for: [0, 0], maxValue: nil) == 1)
    #expect(Sparkline.scaleTop(for: [10], maxValue: .nan) == 11.5)
  }
}
