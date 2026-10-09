import AppKit
import Foundation
import TarteletteKit
import Testing

@testable import Tartelette

@Suite("Single instance")
struct SingleInstanceTests {
  private let earlier = Date(timeIntervalSince1970: 1_000)
  private let later = Date(timeIntervalSince1970: 2_000)

  @Test func theEarliestLaunchedCopySurvives() {
    let instances = [
      AppDelegate.InstanceInfo(pid: 10, launchDate: later),
      AppDelegate.InstanceInfo(pid: 20, launchDate: earlier),
    ]
    #expect(AppDelegate.survivingInstance(among: instances)?.pid == 20)
    #expect(AppDelegate.survivingInstance(among: instances.reversed())?.pid == 20)
  }

  @Test func simultaneousLaunchesAgreeOnTheLowestPID() {
    // Both copies see the same list (in any order) and must pick the same survivor.
    let instances = [
      AppDelegate.InstanceInfo(pid: 42, launchDate: earlier),
      AppDelegate.InstanceInfo(pid: 7, launchDate: earlier),
    ]
    #expect(AppDelegate.survivingInstance(among: instances)?.pid == 7)
    #expect(AppDelegate.survivingInstance(among: instances.reversed())?.pid == 7)
  }

  @Test func copiesWithoutALaunchDateCountAsLaunchedLast() {
    let instances = [
      AppDelegate.InstanceInfo(pid: 1, launchDate: nil),
      AppDelegate.InstanceInfo(pid: 99, launchDate: later),
    ]
    #expect(AppDelegate.survivingInstance(among: instances)?.pid == 99)
    #expect(AppDelegate.survivingInstance(among: [.init(pid: 5, launchDate: nil), .init(pid: 3, launchDate: nil)])?.pid == 3)
    #expect(AppDelegate.survivingInstance(among: []) == nil)
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
