import Foundation

/// A Tart release version such as `2.41.0`.
///
/// Built from a release tag (`2.41.0`, `v2.41.0`) or from the output of `tart --version`. A missing
/// patch component counts as zero, so `2.41` and `2.41.0` are the same version.
public struct TartVersion: Sendable, Hashable, CustomStringConvertible {
  public var major: Int
  public var minor: Int
  public var patch: Int

  public init(major: Int, minor: Int, patch: Int = 0) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Parses `2.41.0`, `v2.41.0` or `2.41`, ignoring surrounding whitespace and newlines.
  ///
  /// Returns `nil` for anything else, including `SNAPSHOT`, the version a locally built Tart reports.
  public init?(_ text: String) {
    var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    if text.hasPrefix("v") { text = text.dropFirst() }

    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
        let number = Int(part)
      else { return nil }
      numbers.append(number)
    }
    self.init(major: numbers[0], minor: numbers[1], patch: numbers.count == 3 ? numbers[2] : 0)
  }

  /// Always three components: `2.41` reads `2.41.0`.
  public var description: String { "\(major).\(minor).\(patch)" }
}

extension TartVersion: Comparable {
  /// Component by component, numerically: `2.9.0 < 2.10.0`.
  public static func < (lhs: TartVersion, rhs: TartVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
