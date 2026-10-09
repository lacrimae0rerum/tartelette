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

  // MARK: R3-004 serialized transfers

  @Test func manualSendDuringAReceiveWaitsForIt() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let controllable = ControllableTransport(wrapping: fixture.transport)
    let host = NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "local", os: .macOS, transport: controllable),
      bridge: fixture.bridge,
      configuration: .init(hostPollInterval: .milliseconds(60), guestPollInterval: .milliseconds(150)),
      hostPasteboard: host)
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    controllable.heavyDelay = .milliseconds(700)
    fixture.guestBoard.clearContents()
    fixture.guestBoard.setString("from the guest", forType: .string)
    #expect(await waitUntil { controllable.heavyCommandCount > 0 }, "the automatic receive must have started")

    host.clearContents()
    host.setString("from the host", forType: .string)
    #expect(await session.sendNow())
    try await Task.sleep(for: .milliseconds(400))
    #expect(controllable.maxConcurrentHeavyCommands == 1, "transfers must never overlap")
    #expect(fixture.guestBoard.string(forType: .string) == "from the host", "the manual send ran after the receive")
  }

  // MARK: R3-005 stable status and back-off

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  static func statusEvents(_ log: EventLog) -> [GuestAgentStatus] {
    log.events.compactMap { if case .guestStatus(let status) = $0 { status } else { nil } }
  }

  @Test func unreachableGuestDoesNotFlapAndBacksOff() async throws {
    let probes = Counter()
    let transport = ScriptedTransport { _, _ in
      probes.increment()
      return CommandOutput(
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
      configuration: .init(guestPollInterval: .milliseconds(20), maximumBackoff: .milliseconds(200)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    try await Task.sleep(for: .milliseconds(1500))
    session.stop()

    let statuses = Self.statusEvents(log)
    #expect(statuses.count == 2, "only .checking and then .unavailable, got \(statuses)")
    #expect(statuses.first == .checking)
    #expect(session.consecutiveGuestFailures >= 4)
    #expect(session.guestDelay == .milliseconds(200))
    // Without back-off a 20 ms poll would probe ~75 times in 1.5 s.
    #expect(probes.count < 15, "probed \(probes.count) times")
  }

  @Test func guestWithoutAClipboardToolIsStablyUnavailable() async throws {
    let transport = ScriptedTransport { command, _ in
      if command.first == "/usr/bin/env" { return CommandOutput(status: 0, stdout: Data("admin\n1000\nLinux\n".utf8)) }
      return CommandOutput(status: GuestScripts.linuxUnsupportedStatus, stderr: Data("No clipboard tool in the guest.".utf8))
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let host = NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "server", os: .linux, transport: transport),
      bridge: ClipboardBridge(fileStagingDirectory: staging),
      configuration: .init(guestPollInterval: .milliseconds(20), maximumBackoff: .milliseconds(300)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    try await Task.sleep(for: .milliseconds(1200))
    session.stop()

    let statuses = Self.statusEvents(log)
    #expect(statuses == [.checking, .unavailable(reason: "No clipboard tool in the guest.")])
    #expect(!statuses.contains { $0.isAvailable }, "an agent without a clipboard must never flip to available")
    #expect(session.guestClipboardUnsupported)
    #expect(session.guestDelay == .milliseconds(300))
  }

  // MARK: R3-006 changes made while the guest is unreachable

  @Test func hostChangesMadeWhileTheGuestIsUnreachableAreSentLater() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let controllable = ControllableTransport(wrapping: fixture.transport)
    let host = NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "local", os: .macOS, transport: controllable),
      bridge: fixture.bridge,
      configuration: .init(
        hostPollInterval: .milliseconds(60), guestPollInterval: .milliseconds(100), maximumBackoff: .milliseconds(400)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    controllable.isReachable = false
    #expect(await waitUntil(timeout: .seconds(5)) { !session.guestStatus.isAvailable })
    host.clearContents()
    host.setString("written while offline", forType: .string)
    try await Task.sleep(for: .milliseconds(500))
    #expect(fixture.guestBoard.string(forType: .string) != "written while offline")

    controllable.isReachable = true
    #expect(await waitUntil { fixture.guestBoard.string(forType: .string) == "written while offline" })
    // The guest board changes inside the write script; the event follows once the script returns.
    #expect(await waitUntil { log.sentCount >= 1 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(log.sentCount == 1)
  }

  // MARK: R3-011 Linux guests keep a single flavour

  @Test func linuxGuestNeverDowngradesARichHostClipboard() async throws {
    let linux = try FakeLinuxClipboard()
    defer { linux.cleanUp() }
    let staging = try TestFiles.temporaryDirectory("tartelette-host-staging")
    defer { try? FileManager.default.removeItem(at: staging) }
    let host = NSPasteboard(name: NSPasteboard.Name("tartelette-test-host-\(UUID().uuidString)"))
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "linux", os: .linux, transport: linux.transport()),
      bridge: ClipboardBridge(fileStagingDirectory: staging),
      configuration: .init(hostPollInterval: .milliseconds(60), guestPollInterval: .milliseconds(150)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    let rich = ClipboardBridgeTests.richText()
    PasteboardCodec.write(rich, to: host)
    #expect(await waitUntil { linux.target("text/plain") == rich.data(for: ClipboardRepresentation.plainText) })

    // Another client re-asserts the same text with an extra target: the token changes, the
    // contents read back are the projection we pushed, and the rich host clipboard stays.
    try Data("1".utf8).write(to: linux.store.appendingPathComponent("TIMESTAMP"))
    try await Task.sleep(for: .seconds(1.5))
    #expect(log.receivedCount == 0)
    #expect(host.data(forType: .rtf) != nil, "the host clipboard must keep its rich text")

    // A genuine guest change still comes through.
    try linux.own("text/plain", Data("typed in the guest".utf8))
    #expect(await waitUntil { host.string(forType: .string) == "typed in the guest" })
    #expect(log.receivedCount == 1)
  }
}
