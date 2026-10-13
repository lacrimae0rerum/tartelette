import Foundation
import TarteletteCore
import Testing
import os

@testable import TarteletteGuest

@Suite("Guest shutdown requests")
struct GuestShutdownTests {
  /// Records every command and answers with a canned reply.
  final class FakeTransport: GuestTransport, Sendable {
    struct Call: Sendable, Equatable {
      var command: [String]
      var timeout: Duration?
    }

    let label = "fake"
    private let reply: @Sendable () async throws -> CommandOutput
    private let recorded = OSAllocatedUnfairLock(initialState: [Call]())

    init(reply: @escaping @Sendable () async throws -> CommandOutput) {
      self.reply = reply
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func run(_ command: [String], standardInput: Data?, timeout: Duration?) async throws -> CommandOutput {
      recorded.withLock { $0.append(Call(command: command, timeout: timeout)) }
      return try await reply()
    }
  }

  /// Counts calls, e.g. to the caller's own stop request (SIGUSR2 to `tart run` in the app).
  final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
  }

  private static let loginwindowShutdown = [
    "/usr/bin/osascript", "-e", "tell application \"loginwindow\" to «event aevtshut»",
  ]

  // MARK: In-guest request

  @Test func asksLoginwindowToShutDownWithAShortDeliveryTimeout() async {
    let transport = FakeTransport { CommandOutput(status: 0) }

    let delivery = await GuestShutdown.requestInGuest(through: transport)

    #expect(delivery == .delivered)
    #expect(transport.calls == [.init(command: Self.loginwindowShutdown, timeout: .seconds(15))])
  }

  @Test func anUnreachableAgentIsNotADelivery() async {
    let transport = FakeTransport { throw GuestTransportError.unreachable("The guest agent is not running.") }

    let delivery = await GuestShutdown.requestInGuest(through: transport)

    #expect(delivery == .notDelivered(reason: "The guest agent is not running."))
  }

  @Test func aFailedRequestIsNotADelivery() async {
    let transport = FakeTransport {
      CommandOutput(status: 1, stderr: Data("execution error: Not authorized to send Apple events (-1743)\n".utf8))
    }

    let delivery = await GuestShutdown.requestInGuest(through: transport)

    #expect(delivery == .notDelivered(reason: "execution error: Not authorized to send Apple events (-1743)"))
  }

  @Test func aFailedRequestWithoutOutputReportsItsExitCode() async {
    let transport = FakeTransport { CommandOutput(status: 127) }

    let delivery = await GuestShutdown.requestInGuest(through: transport)

    #expect(delivery == .notDelivered(reason: "The shutdown request failed with exit code 127."))
  }

  @Test func aRequestThatTimesOutIsNotADelivery() async {
    let transport = FakeTransport { throw ProcessRunError.timedOut(after: .seconds(15)) }

    let delivery = await GuestShutdown.requestInGuest(through: transport, timeout: .seconds(15))

    guard case .notDelivered(let reason) = delivery else {
      Issue.record("expected notDelivered, got \(delivery)")
      return
    }
    #expect(reason.contains("timed out"))
  }

  // MARK: Choosing the request

  @Test func aMacOSGuestIsAskedFromInsideAndNotWithTheStopRequest() async throws {
    let transport = FakeTransport { CommandOutput(status: 0) }
    let stopRequest = Counter()

    let request = try await GuestShutdown.request(for: .macOS, through: transport) { stopRequest.increment() }

    #expect(request == .inGuest)
    #expect(transport.calls.map(\.command) == [Self.loginwindowShutdown])
    #expect(stopRequest.value == 0)
  }

  @Test func aMacOSGuestGetsTheStopRequestWhenTheInGuestRequestIsNotDelivered() async throws {
    let transport = FakeTransport { throw GuestTransportError.unreachable("no agent") }
    let stopRequest = Counter()

    let request = try await GuestShutdown.request(for: .macOS, through: transport) { stopRequest.increment() }

    #expect(request == .stopRequest)
    #expect(transport.calls.count == 1)
    #expect(stopRequest.value == 1)
  }

  @Test(arguments: [VMOperatingSystem.linux, .unknown])
  func otherGuestsGetOnlyTheStopRequest(os: VMOperatingSystem) async throws {
    let transport = FakeTransport { CommandOutput(status: 0) }
    let stopRequest = Counter()

    let request = try await GuestShutdown.request(for: os, through: transport) { stopRequest.increment() }

    #expect(request == .stopRequest)
    #expect(transport.calls.isEmpty)
    #expect(stopRequest.value == 1)
  }

  @Test func stopRequestFailuresReachTheCaller() async {
    struct NotRunning: Error, Equatable {}
    let transport = FakeTransport { CommandOutput(status: 1) }

    await #expect(throws: NotRunning()) {
      try await GuestShutdown.request(for: .macOS, through: transport) { throw NotRunning() }
    }
    await #expect(throws: NotRunning()) {
      try await GuestShutdown.request(for: .linux, through: transport) { throw NotRunning() }
    }
  }

  // MARK: Asking every guest on quit

  private static func target(
    _ name: String, _ os: VMOperatingSystem, _ transport: FakeTransport, stopRequests: Counter
  ) -> GuestShutdown.Target {
    GuestShutdown.Target(name: name, os: os, transport: transport) { stopRequests.increment() }
  }

  /// Answers long after any test's limit, ignoring cancellation, like a request that hangs.
  private static func hangingReply(for duration: Duration, then status: Int32) -> @Sendable () async -> CommandOutput {
    {
      await Task { try? await Task.sleep(for: duration) }.value
      return CommandOutput(status: status)
    }
  }

  @Test func everyGuestGetsTheRequestItsOSHonours() async {
    let mac = FakeTransport { CommandOutput(status: 0) }
    let macWithoutAgent = FakeTransport { throw GuestTransportError.unreachable("no agent") }
    let linux = FakeTransport { CommandOutput(status: 0) }
    let stopRequests = [Counter(), Counter(), Counter()]

    let requests = await GuestShutdown.requestAll(
      [
        Self.target("mac", .macOS, mac, stopRequests: stopRequests[0]),
        Self.target("mac-no-agent", .macOS, macWithoutAgent, stopRequests: stopRequests[1]),
        Self.target("ubuntu", .linux, linux, stopRequests: stopRequests[2]),
      ], waitingAtMost: .seconds(10))

    #expect(requests == ["mac": .inGuest, "mac-no-agent": .stopRequest, "ubuntu": .stopRequest])
    #expect(stopRequests.map(\.value) == [0, 1, 1])
    #expect(mac.calls.map(\.command) == [Self.loginwindowShutdown])
    #expect(linux.calls.isEmpty)
  }

  @Test func guestsAreAskedAllAtOnce() async {
    // Each request answers only once both have started: asked one after the other, the first
    // would still be waiting at the limit.
    let arrivals = Counter()
    let reply: @Sendable () async throws -> CommandOutput = {
      arrivals.increment()
      while arrivals.value < 2 { try await Task.sleep(for: .milliseconds(5)) }
      return CommandOutput(status: 0)
    }
    let stopRequests = Counter()

    let requests = await GuestShutdown.requestAll(
      [
        Self.target("one", .macOS, FakeTransport(reply: reply), stopRequests: stopRequests),
        Self.target("two", .macOS, FakeTransport(reply: reply), stopRequests: stopRequests),
      ], waitingAtMost: .seconds(10))

    #expect(requests == ["one": .inGuest, "two": .inGuest])
    #expect(stopRequests.value == 0)
  }

  @Test func theWaitEndsAtTheLimitEvenWhenARequestHangs() async {
    // The wait must end long before the hanging request answers. The bound is half the hang rather
    // than a few seconds: the limit fires on time even on a loaded machine, but resuming this test
    // afterwards can take seconds when other tests keep every thread of the concurrency pool busy.
    let hang: Duration = .seconds(60)
    let hanging = FakeTransport(reply: Self.hangingReply(for: hang, then: 0))
    let linux = FakeTransport { CommandOutput(status: 0) }
    let macStopRequests = Counter()
    let linuxStopRequests = Counter()
    let started = ContinuousClock.now

    let requests = await GuestShutdown.requestAll(
      [
        Self.target("mac", .macOS, hanging, stopRequests: macStopRequests),
        Self.target("ubuntu", .linux, linux, stopRequests: linuxStopRequests),
      ], waitingAtMost: .milliseconds(200))

    #expect(ContinuousClock.now - started < hang / 2)
    // The in-guest request wasn't delivered in time, so the macOS guest got the stop request too.
    #expect(requests == ["mac": .stopRequest, "ubuntu": .stopRequest])
    #expect(macStopRequests.value == 1)
    #expect(linuxStopRequests.value == 1)
  }

  @Test func aRequestThatFailsAfterTheLimitSendsNoSecondStopRequest() async throws {
    let late = FakeTransport(reply: Self.hangingReply(for: .milliseconds(300), then: 1))
    let stopRequests = Counter()

    let requests = await GuestShutdown.requestAll(
      [Self.target("mac", .macOS, late, stopRequests: stopRequests)], waitingAtMost: .milliseconds(50))
    try await Task.sleep(for: .seconds(1))

    #expect(requests == ["mac": .stopRequest])
    #expect(stopRequests.value == 1)
  }

  @Test func aFailedStopRequestLeavesTheGuestOutOfTheResult() async {
    struct NotRunning: Error {}
    let target = GuestShutdown.Target(name: "ubuntu", os: .linux, transport: FakeTransport { CommandOutput(status: 0) }) {
      throw NotRunning()
    }

    let requests = await GuestShutdown.requestAll([target], waitingAtMost: .seconds(10))

    #expect(requests.isEmpty)
  }
}
