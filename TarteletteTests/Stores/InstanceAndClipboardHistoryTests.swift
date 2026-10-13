import AppKit
import Foundation
import TarteletteKit
import Testing

@testable import Tartelette

@Suite("Single instance guard")
struct SingleInstanceGuardTests {
  private let bundleIdentifier = "io.github.lacrimae0rerum.Tartelette"
  private let ownPID: pid_t = 500
  private let earlier = Date(timeIntervalSince1970: 1_000)
  private let later = Date(timeIntervalSince1970: 2_000)

  private func decision(
    running: [SingleInstanceGuard.Instance], launchedAt: Date? = nil, environment: [String: String] = [:]
  ) -> SingleInstanceGuard.Decision {
    SingleInstanceGuard(
      bundleIdentifier: bundleIdentifier, ownPID: ownPID, ownLaunchDate: launchedAt ?? later, environment: environment
    ).decide(running: running)
  }

  /// The decision the given copy makes about the others.
  private func decision(
    running: [SingleInstanceGuard.Instance], as own: SingleInstanceGuard.Instance
  ) -> SingleInstanceGuard.Decision {
    SingleInstanceGuard(
      bundleIdentifier: bundleIdentifier, ownPID: own.pid, ownLaunchDate: own.launchDate, environment: [:]
    ).decide(running: running)
  }

  private func copy(
    pid: pid_t, bundleIdentifier: String? = nil, path: String = "/Applications/Tartelette.app",
    version: String? = "1.0.0", launchedAt: Date? = nil, finishedLaunching: Bool = true
  ) -> SingleInstanceGuard.Instance {
    SingleInstanceGuard.Instance(
      pid: pid, bundleIdentifier: bundleIdentifier ?? self.bundleIdentifier, bundleURL: URL(fileURLWithPath: path),
      version: version, launchDate: launchedAt ?? earlier, isFinishedLaunching: finishedLaunching)
  }

  @Test func aLoneCopyLaunches() {
    #expect(decision(running: []) == .proceed)
    #expect(decision(running: [copy(pid: ownPID, path: "/Volumes/Work/Tartelette.app", launchedAt: later)]) == .proceed)
  }

  @Test func anotherCopyIsAConflictNamingItsPIDLocationAndVersion() {
    let own = copy(pid: ownPID, path: "/Volumes/Work/Tartelette.app", version: "1.1.0", launchedAt: later)
    let other = copy(pid: 42, path: "/Applications/Tartelette.app", version: "1.0.0")

    let expected = SingleInstanceGuard.Instance(
      pid: 42, bundleIdentifier: bundleIdentifier, bundleURL: URL(fileURLWithPath: "/Applications/Tartelette.app"),
      version: "1.0.0", launchDate: earlier, isFinishedLaunching: true)
    #expect(decision(running: [own, other]) == .conflict(with: expected))
    #expect(decision(running: [other, own]) == .conflict(with: expected))
  }

  @Test func otherAppsAreIgnored() {
    let helper = copy(pid: 77, bundleIdentifier: "io.github.lacrimae0rerum.tartelette-mcp")
    #expect(decision(running: [helper]) == .proceed)
  }

  @Test func anXCTestHostLaunchesNextToAnOpenCopy() {
    for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
      #expect(decision(running: [copy(pid: 42)], environment: [key: "1"]) == .proceed, "\(key)")
    }
  }

  @Test func withSeveralCopiesTheEarliestLaunchedIsNamed() {
    let first = copy(pid: 90, launchedAt: Date(timeIntervalSince1970: 100))
    let second = copy(pid: 30, launchedAt: Date(timeIntervalSince1970: 200))
    #expect(decision(running: [second, first]) == .conflict(with: first))
    #expect(decision(running: [first, second]) == .conflict(with: first))

    // Same launch date: the lowest PID; copies without a launch date count as launched last.
    let sameTime = [copy(pid: 61, launchedAt: earlier), copy(pid: 60, launchedAt: earlier)]
    #expect(decision(running: sameTime) == .conflict(with: copy(pid: 60, launchedAt: earlier)))
    var undated = copy(pid: 1)
    undated.launchDate = nil
    #expect(decision(running: [undated, second]) == .conflict(with: second))
    var undatedLowerPID = copy(pid: 0)
    undatedLowerPID.launchDate = nil
    #expect(decision(running: [undated, undatedLowerPID]) == .conflict(with: undatedLowerPID))
  }

  @Test func twoCopiesLaunchingTogetherOnlyTheLaterOneAsks() {
    // Each copy sees the other still launching: the later one asks, the earlier one carries on.
    let first = copy(pid: 600, path: "/Applications/Tartelette.app", launchedAt: earlier, finishedLaunching: false)
    let second = copy(pid: 400, path: "/Volumes/Work/Tartelette.app", launchedAt: later, finishedLaunching: false)
    #expect(decision(running: [first, second], as: first) == .proceed)
    #expect(decision(running: [first, second], as: second) == .conflict(with: first))

    // A later copy that already finished launching runs: the earlier one asks about it too.
    var running = second
    running.isFinishedLaunching = true
    #expect(decision(running: [first, running], as: first) == .conflict(with: running))
  }

  @Test func theAlertNamesTheOpenCopysVersionAndLocation() {
    let reason = "Only one copy can run at a time, because both would manage the same VMs and settings."
    var other = copy(pid: 42, path: "/Applications/Tartelette.app", version: "1.0.0")
    #expect(
      SingleInstanceGuard.conflictMessage(for: other)
        == "Tartelette 1.0.0 is already open from “/Applications/Tartelette.app”. \(reason)")

    other.version = nil
    #expect(
      SingleInstanceGuard.conflictMessage(for: other)
        == "Another copy of Tartelette is already open from “/Applications/Tartelette.app”. \(reason)")

    other.bundleURL = nil
    #expect(SingleInstanceGuard.conflictMessage(for: other) == "Another copy of Tartelette is already open. \(reason)")
  }
}

@Suite("Clipboard history", .serialized)
struct ClipboardHistoryTests {
  private func board(text: String) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("tartelette-history-\(UUID().uuidString)"))
    board.clearContents()
    board.setString(text, forType: .string)
    return board
  }

  @Test func receivedPayloadIsRecordedFromTheClipboardRightAway() throws {
    let board = board(text: "from the guest")
    defer { board.releaseGlobally() }
    let summary = try #require(PasteboardCodec.snapshot(board)?.summary)
    let state = VMClipboardState(liveSyncEnabled: true)

    ClipboardCenter.apply(.receivedFromGuest(summary: summary, date: .now), to: state, pasteboard: board)

    #expect(state.lastReceived?.plainText == "from the guest")
    #expect(state.lastReceivedSummary == summary)
    #expect(state.events.first?.kind == .received)
  }

  @Test func somethingCopiedInBetweenIsNotRecordedAsReceived() {
    // The Mac clipboard already holds something else when the event is handled.
    let board = board(text: "copied on the Mac afterwards")
    defer { board.releaseGlobally() }
    let state = VMClipboardState(liveSyncEnabled: true)

    ClipboardCenter.apply(.receivedFromGuest(summary: "Image · PNG · 2 KB", date: .now), to: state, pasteboard: board)

    #expect(state.lastReceived == nil)
    #expect(state.lastReceivedSummary == "Image · PNG · 2 KB")
  }
}
