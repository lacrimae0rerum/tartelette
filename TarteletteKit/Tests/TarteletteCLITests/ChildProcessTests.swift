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
}
