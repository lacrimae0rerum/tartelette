import AppKit

/// Applies `SingleInstanceGuard` at launch: when another copy of Tartelette is open, asks which one
/// to keep.
enum SingleInstanceLaunch {
  /// How long to wait for the other copy to quit after asking it to.
  static let quitTimeout: TimeInterval = 15

  /// Whether this copy should finish launching. When it returns false the caller quits right away;
  /// this copy hasn't started anything yet.
  static func shouldFinishLaunching() -> Bool {
    let current = NSRunningApplication.current
    guard let identifier = Bundle.main.bundleIdentifier else { return true }
    let instanceGuard = SingleInstanceGuard(
      bundleIdentifier: identifier, ownPID: current.processIdentifier, ownLaunchDate: current.launchDate,
      environment: ProcessInfo.processInfo.environment)
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
    guard case .conflict(let other) = instanceGuard.decide(running: running.map(SingleInstanceGuard.Instance.init)),
      let otherApp = running.first(where: { $0.processIdentifier == other.pid })
    else { return true }

    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Tartelette is already open"
    alert.informativeText = SingleInstanceGuard.conflictMessage(for: other)
    alert.addButton(withTitle: "Use the Open Copy")
    alert.addButton(withTitle: "Quit It and Use This Copy")
    guard alert.runModal() == .alertSecondButtonReturn else {
      bringForward(otherApp)
      return false
    }

    // `terminate()` runs the other copy's usual quit path (including stopping its VMs if set).
    if otherApp.terminate(), waitForExit(of: otherApp.processIdentifier) { return true }
    let failure = NSAlert()
    failure.messageText = "Tartelette couldn't quit the other copy"
    failure.informativeText =
      "It didn't quit within \(Int(quitTimeout)) seconds, so this copy quits instead. "
      + "Quit the other copy, then open this one again."
    failure.runModal()
    bringForward(otherApp)
    return false
  }

  private static func bringForward(_ app: NSRunningApplication) {
    NSApp.yieldActivation(to: app)
    app.activate()
  }

  /// Polls for the process to exit. The main run loop isn't running yet during launch, so
  /// `NSRunningApplication.isTerminated` wouldn't update.
  private static func waitForExit(of pid: pid_t) -> Bool {
    let deadline = Date.now.addingTimeInterval(quitTimeout)
    repeat {
      if kill(pid, 0) != 0, errno == ESRCH { return true }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date.now < deadline
    return false
  }
}

extension SingleInstanceGuard.Instance {
  init(_ app: NSRunningApplication) {
    self.init(
      pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL,
      version: app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String },
      launchDate: app.launchDate, isFinishedLaunching: app.isFinishedLaunching)
  }
}
