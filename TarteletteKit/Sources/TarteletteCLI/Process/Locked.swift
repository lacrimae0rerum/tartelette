import Foundation

/// A tiny lock-protected box for state shared between dispatch callbacks and async callers.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  @discardableResult
  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }

  var current: Value {
    withLock { $0 }
  }
}

extension Duration {
  /// The duration as fractional seconds, for Dispatch deadlines.
  var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}

enum ProcessEnvironment {
  /// The app's own environment with `overrides` applied on top and `removed` keys dropped.
  static func merged(_ overrides: [String: String], removing removed: Set<String> = []) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in removed { environment.removeValue(forKey: key) }
    environment.merge(overrides) { _, new in new }
    return environment
  }
}
