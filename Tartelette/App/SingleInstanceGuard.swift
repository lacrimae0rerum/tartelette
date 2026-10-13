import Foundation

/// Decides whether this copy of the app may finish launching, given the copies already running.
///
/// LaunchServices only reuses a running instance when the same copy is opened again, so another
/// copy (say, one in /Applications and a newer build elsewhere) can start next to it. Both would
/// share the same settings and manage the same VMs, so only one copy runs at a time.
struct SingleInstanceGuard {
  /// One running copy of the app, as the guard sees it.
  struct Instance: Equatable {
    var pid: pid_t
    var bundleIdentifier: String?
    var bundleURL: URL?
    var version: String?
    var launchDate: Date?
    var isFinishedLaunching = true
  }

  enum Decision: Equatable {
    case proceed
    /// Another copy runs: the user chooses which one to keep.
    case conflict(with: Instance)
  }

  var bundleIdentifier: String?
  var ownPID: pid_t
  var ownLaunchDate: Date?
  var environment: [String: String]

  /// Set when XCTest launches the app as its test host, next to any copy already running.
  static let testHostEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

  func decide(running: [Instance]) -> Decision {
    guard let bundleIdentifier, !Self.testHostEnvironmentKeys.contains(where: { environment[$0] != nil }) else {
      return .proceed
    }
    let own = Instance(pid: ownPID, bundleIdentifier: bundleIdentifier, launchDate: ownLaunchDate)
    let others = running.filter { other in
      // A later copy that is still launching sees this one and asks there, so two copies started
      // together never both ask (or both give way).
      other.pid != ownPID && other.bundleIdentifier == bundleIdentifier
        && (other.isFinishedLaunching || Self.launchedEarlier(other, own))
    }
    guard let other = others.min(by: Self.launchedEarlier) else { return .proceed }
    return .conflict(with: other)
  }

  /// Explains the conflict in the launch alert, naming the open copy's version and location when known.
  static func conflictMessage(for other: Instance) -> String {
    let who = other.version.map { "Tartelette \($0)" } ?? "Another copy of Tartelette"
    let location = other.bundleURL.map { " from “\(($0.path as NSString).abbreviatingWithTildeInPath)”" } ?? ""
    return "\(who) is already open\(location). "
      + "Only one copy can run at a time, because both would manage the same VMs and settings."
  }

  /// Launch order: the earliest launch date first (copies without one count as launched last),
  /// then the lowest PID, so every copy orders the same list the same way.
  static func launchedEarlier(_ lhs: Instance, _ rhs: Instance) -> Bool {
    switch (lhs.launchDate, rhs.launchDate) {
    case let (left?, right?) where left != right: left < right
    case (.some, nil): true
    case (nil, .some): false
    default: lhs.pid < rhs.pid
    }
  }
}
