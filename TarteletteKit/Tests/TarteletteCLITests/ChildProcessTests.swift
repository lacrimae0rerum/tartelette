import Foundation
import Testing

@testable import TarteletteCLI

@Suite("Child process stream ordering")
struct ChildProcessTests {
  /// Records the order of callbacks from several threads.
  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
      lock.lock()
      entries.append(entry)
      lock.unlock()
    }

    var snapshot: [String] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }
  }

  /// Completion must never overtake a stream's close handler: callers flush their last partial
  /// line there (e.g. Tart's final `100%` without a newline) and finish their event stream on
  /// completion, so an early completion silently drops that output.
  @Test func completionWaitsForSlowStreamCloseHandlers() async throws {
    for _ in 0..<5 {
      let recorder = Recorder()
      let child = ChildProcess(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf out; printf err >&2"],
        environment: ProcessInfo.processInfo.environment,
        standardInput: nil,
        handlers: .init(
          standardOutput: { _ in },
          standardError: { _ in },
          standardOutputClosed: {
            Thread.sleep(forTimeInterval: 0.2)
            recorder.record("stdout-closed")
          },
          standardErrorClosed: { recorder.record("stderr-closed") }
        )
      )
      let status: Int32 = await withCheckedContinuation { continuation in
        do {
          try child.start { status in
            recorder.record("completed")
            continuation.resume(returning: status)
          }
        } catch {
          continuation.resume(returning: -1)
        }
      }
      #expect(status == 0)
      #expect(recorder.snapshot.last == "completed")
      #expect(recorder.snapshot.filter { $0 == "completed" }.count == 1)
      #expect(Set(recorder.snapshot) == ["stdout-closed", "stderr-closed", "completed"])
    }
  }

  /// A grandchild keeps the pipes open, so the streams are closed by the grace period while a data
  /// delivery is still in flight. That delivery must land before the close handler, and nothing may
  /// be delivered after it (the grandchild's later output is dropped deterministically).
  @Test func graceCloseWaitsForInFlightDeliveryAndDropsLaterOutput() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("grandchild-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let recorder = Recorder()
    let child = ChildProcess(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "(sleep 1; echo late) & echo $! > \"$1\"; echo early", "sh", pidFile.path],
      environment: ProcessInfo.processInfo.environment,
      standardInput: nil,
      handlers: .init(
        standardOutput: { data in
          let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          // Still being delivered when the 0.3 s grace period closes the stream.
          if text.contains("early") { Thread.sleep(forTimeInterval: 0.6) }
          recorder.record("data:\(text)")
        },
        standardError: { _ in },
        standardOutputClosed: { recorder.record("stdout-closed") },
        standardErrorClosed: { recorder.record("stderr-closed") }
      ),
      streamGracePeriod: 0.3
    )
    defer {
      // Never leave the grandchild behind.
      if let text = try? String(contentsOf: pidFile, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        kill(pid, SIGKILL)
      }
    }
    let status: Int32 = await withCheckedContinuation { continuation in
      do {
        try child.start { status in
          recorder.record("completed")
          continuation.resume(returning: status)
        }
      } catch {
        continuation.resume(returning: -1)
      }
    }
    // The grandchild writes its late line about 1 s after starting.
    try await Task.sleep(for: .milliseconds(900))

    let events = recorder.snapshot
    #expect(status == 0)
    #expect(events.filter { $0 == "completed" }.count == 1)
    let early = try #require(events.firstIndex(of: "data:early"), "events: \(events)")
    let closed = try #require(events.firstIndex(of: "stdout-closed"), "events: \(events)")
    #expect(early < closed, "events: \(events)")
    #expect(!events[closed...].contains { $0.hasPrefix("data:") }, "events: \(events)")
  }
}
