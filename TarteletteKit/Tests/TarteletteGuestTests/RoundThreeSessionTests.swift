import AppKit
import Foundation
import TarteletteCore
import Testing

@testable import TarteletteGuest

/// Review round 3: bounded incomplete guest reads, quiet transient failures, observable echo
/// suppression, and the real guest read script against an unresolved lazy file item.
@Suite("Session review round 3", .serialized)
@MainActor
struct RoundThreeSessionTests {
  nonisolated static let incompleteManifest = #"{"changeCount":7,"incomplete":true,"items":[],"files":[]}"#

  // MARK: R3-guest-pending-unbounded

  @Test func aGuestCopyThatStaysIncompleteIsReportedOnceThenLeftAlone() async throws {
    let reads = SyncSettlingTests.Counter()
    let queries = SyncSettlingTests.Counter()
    let transport = ScriptedTransport { command, _ in
      let joined = command.joined(separator: " ")
      if command.first == "/usr/bin/env" {
        return CommandOutput(status: 0, stdout: Data("admin\n501\nDarwin\nadmin\n".utf8))
      }
      if joined.contains("emit({ changeCount: Number(board(argv[0]).changeCount) })") {
        queries.increment()
        return CommandOutput(status: 0, stdout: Data(#"{"changeCount":\#(queries.count == 1 ? 6 : 7)}"#.utf8))
      }
      if joined.contains("readFileItems") {
        reads.increment()
        return CommandOutput(status: 0, stdout: Data(Self.incompleteManifest.utf8))
      }
      return CommandOutput(status: 0)
    }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let host = SyncSettlingTests.hostBoard()
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: GuestEndpoint(vmName: "vm", os: .macOS, transport: transport),
      bridge: ClipboardBridge(fileStagingDirectory: staging),
      configuration: .init(
        direction: .guestToHost, guestPollInterval: .milliseconds(80), guestSettleDelay: .zero,
        incompleteReportDelay: .milliseconds(400)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }

    // The report is due 400 ms after the stuck copy is first seen; the wait only bounds a loaded
    // main actor, so it uses the helper's default budget.
    #expect(await waitUntil { !log.skipped.isEmpty })
    let readsAtReport = reads.count
    try await Task.sleep(for: .milliseconds(800))
    #expect(log.skipped.count == 1, "reported once: \(log.skipped)")
    #expect(log.skipped.first?.contains("couldn't be read") == true)
    #expect(reads.count <= readsAtReport + 1, "the stuck copy is no longer re-read (\(readsAtReport) → \(reads.count))")
  }

  // MARK: R3-transient-pull-failure-spam

  @Test func transientPullFailuresDoNotRepeatFailureEvents() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let controllable = ControllableTransport(wrapping: fixture.transport)
    let host = SyncSettlingTests.hostBoard()
    defer { host.releaseGlobally() }
    let session = SyncSettlingTests.makeSession(fixture, transport: controllable, host: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    let failedReads = SyncSettlingTests.Counter()
    controllable.unreachableWhen = { command in
      let isRead = command.contains { $0.contains("readFileItems") }
      if isRead { failedReads.increment() }
      return isRead && failedReads.count <= 3
    }
    fixture.guestBoard.clearContents()
    fixture.guestBoard.setString("flaky link", forType: .string)
    #expect(await waitUntil { host.string(forType: .string) == "flaky link" })
    #expect(failedReads.count >= 3)
    let failures = log.events.filter { if case .failed = $0 { true } else { false } }
    #expect(failures.isEmpty, "transient failures stay quiet: \(failures)")
  }

  // MARK: R3-degraded-echo-suppresses-real-copies

  @Test func aSuppressedSubsetCopyIsReportedAndACopyAfterTheWindowSyncs() async throws {
    let fixture = try ClipboardBridgeTests.makeFixture()
    defer { fixture.cleanUp() }
    let host = SyncSettlingTests.hostBoard()
    defer { host.releaseGlobally() }
    let session = ClipboardSyncSession(
      endpoint: fixture.endpoint,
      bridge: fixture.bridge,
      configuration: .init(
        direction: .hostToGuest, hostPollInterval: .milliseconds(60), guestPollInterval: .milliseconds(150),
        degradedEchoWindow: .milliseconds(1500)),
      hostPasteboard: host)
    let log = EventLog()
    let collector = Task { @MainActor in for await event in session.events { log.events.append(event) } }
    defer { collector.cancel() }
    session.start()
    defer { session.stop() }
    #expect(await waitUntil { session.guestStatus.isAvailable })

    let (directory, files) = try DegradedEchoTests.makeFiles()
    defer { try? FileManager.default.removeItem(at: directory) }
    DegradedEchoTests.writeFileURLs(files, to: host)
    #expect(await waitUntil { log.sentCount == 1 })

    // A deliberate copy of some of the files just synced, inside the window.
    DegradedEchoTests.writeFileURLs([files[0]], to: host)
    #expect(await waitUntil(timeout: .seconds(3)) { log.skipped.contains { $0.contains("echo") } })
    try await Task.sleep(for: .milliseconds(300))
    #expect(log.skipped.filter { $0.contains("echo") }.count == 1, "reported once: \(log.skipped)")
    #expect(log.sentCount == 1)

    // After the window the same copy goes through.
    try await Task.sleep(for: .milliseconds(1500))
    DegradedEchoTests.writeFileURLs([files[0]], to: host)
    #expect(await waitUntil(timeout: .seconds(5)) { log.sentCount == 2 })
  }

  // MARK: R3-guest-incomplete-script-untested

  @Test func theGuestReadScriptReportsUnresolvedLazyFileItems() async throws {
    let (directory, files) = try IncompleteReadTests.makeFiles(["first.txt", "second.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }
    let staging = try TestFiles.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    // A pasteboard whose second item is promised by a provider that never hands it over.
    let stuckName = "tartelette-lazy-\(UUID().uuidString)"
    let stuck = NSPasteboard(name: NSPasteboard.Name(stuckName))
    defer { stuck.releaseGlobally() }
    let neverReady = LazyFileURLProvider(url: files[1])
    IncompleteReadTests.writeEagerAndLazy(files[0], neverReady, to: stuck)

    let unresolved = try await LocalTransport().run(
      GuestScripts.macOSRead(pasteboardName: stuckName, stagingDirectory: staging.path, inlineLimit: 1 << 20),
      standardInput: nil, timeout: .seconds(30))
    let first = try JSONSerialization.jsonObject(with: unresolved.stdout) as? [String: Any]
    #expect(first?["incomplete"] as? Bool == true, "\(unresolved.stdoutString) \(unresolved.stderrString)")

    // The same shape where the provider hands the item over when asked.
    let readyName = "tartelette-lazy-\(UUID().uuidString)"
    let ready = NSPasteboard(name: NSPasteboard.Name(readyName))
    defer { ready.releaseGlobally() }
    let provider = LazyFileURLProvider(url: files[1])
    provider.ready = true
    IncompleteReadTests.writeEagerAndLazy(files[0], provider, to: ready)

    let resolved = try await LocalTransport().run(
      GuestScripts.macOSRead(pasteboardName: readyName, stagingDirectory: staging.path, inlineLimit: 1 << 20),
      standardInput: nil, timeout: .seconds(30))
    let second = try JSONSerialization.jsonObject(with: resolved.stdout) as? [String: Any]
    #expect(second?["incomplete"] as? Bool != true, "\(resolved.stdoutString)")
    let paths = (second?["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
    #expect(paths.map { ($0 as NSString).lastPathComponent } == ["first.txt", "second.txt"], "\(resolved.stdoutString)")
  }
}
