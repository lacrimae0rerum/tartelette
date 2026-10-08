import AppKit
import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

@MainActor
final class EventLog {
  var events: [ClipboardSyncEvent] = []

  var sentCount: Int { events.filter { if case .sentToGuest = $0 { true } else { false } }.count }
  var receivedCount: Int { events.filter { if case .receivedFromGuest = $0 { true } else { false } }.count }
  var skipped: [String] { events.compactMap { if case .skipped(let reason) = $0 { reason } else { nil } } }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return condition()
}

@Suite("Clipboard sync session", .serialized)
@MainActor
struct ClipboardSyncSessionTests {
  @MainActor
  struct Harness {
    let session: ClipboardSyncSession
    let host: NSPasteboard
    let fixture: ClipboardBridgeTests.Fixture
    let log: EventLog
    let collector: Task<Void, Never>

    func tearDown() {
      session.stop()
      collector.cancel()
      host.releaseGlobally()
      fixture.cleanUp()
    }
  }

  static func makeHarness(maxBytes: Int = 50 * 1024 * 1024) throws -> Harness {
    let fixture = try ClipboardBridgeTests.makeFixture()
    let host = NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
    host.clearContents()
    let session = ClipboardSyncSession(
      endpoint: fixture.endpoint,
      bridge: fixture.bridge,
      configuration: .init(
        hostPollInterval: .milliseconds(60), guestPollInterval: .milliseconds(150), maxAutomaticTransferBytes: maxBytes),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in
      for await event in session.events { log.events.append(event) }
    }
    return Harness(session: session, host: host, fixture: fixture, log: log, collector: collector)
  }

  @Test func changesPropagateOnceInEachDirectionWithoutEcho() async throws {
    let harness = try Self.makeHarness()
    defer { harness.tearDown() }
    harness.session.start()
    #expect(await waitUntil { harness.session.guestStatus.isAvailable })

    // Host → guest.
    harness.host.clearContents()
    harness.host.setString("hello from the host", forType: .string)
    let hostChangeCount = harness.host.changeCount
    #expect(await waitUntil { harness.fixture.guestBoard.string(forType: .string) == "hello from the host" })
    try await Task.sleep(for: .seconds(1.5))
    #expect(harness.log.sentCount == 1)
    #expect(harness.log.receivedCount == 0)
    #expect(harness.host.changeCount == hostChangeCount, "the host pasteboard must not be rewritten (echo)")

    // Guest → host.
    harness.fixture.guestBoard.clearContents()
    harness.fixture.guestBoard.setString("hello from the guest", forType: .string)
    #expect(await waitUntil { harness.host.string(forType: .string) == "hello from the guest" })
    try await Task.sleep(for: .seconds(1.5))
    #expect(harness.log.receivedCount == 1)
    #expect(harness.log.sentCount == 1, "the received payload must not bounce back to the guest")
  }

  @Test func oversizedHostChangesAreSkipped() async throws {
    let harness = try Self.makeHarness(maxBytes: 4)
    defer { harness.tearDown() }
    harness.session.start()
    #expect(await waitUntil { harness.session.guestStatus.isAvailable })

    harness.host.clearContents()
    harness.host.setString("definitely more than four bytes", forType: .string)
    #expect(await waitUntil { !harness.log.skipped.isEmpty })
    #expect(harness.log.sentCount == 0)

    // A manual send ignores the limit.
    #expect(await harness.session.sendNow())
    #expect(harness.fixture.guestBoard.string(forType: .string) == "definitely more than four bytes")
  }

  @Test func fetchNowCopiesTheGuestClipboard() async throws {
    let harness = try Self.makeHarness()
    defer { harness.tearDown() }
    harness.fixture.guestBoard.clearContents()
    harness.fixture.guestBoard.setString("manual fetch", forType: .string)
    #expect(await harness.session.fetchNow())
    #expect(harness.host.string(forType: .string) == "manual fetch")
  }

  @Test func unreachableGuestReportsStatusAndBacksOff() async throws {
    let transport = ScriptedTransport { _, _ in
      CommandOutput(
        status: 1,
        stderr: Data("Failed to connect to the VM using its control socket: deadline, is the Tart Guest Agent running?".utf8))
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let host = NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "vm", os: .macOS, transport: transport),
      bridge: ClipboardBridge(fileStagingDirectory: staging),
      configuration: .init(guestPollInterval: .milliseconds(100)),
      hostPasteboard: host)
    session.start()
    defer { session.stop() }
    #expect(await waitUntil(timeout: .seconds(5)) { if case .unavailable = session.guestStatus { true } else { false } })
    if case .unavailable(let reason) = session.guestStatus {
      #expect(reason.contains("Tart Guest Agent"))
    }
  }
}
