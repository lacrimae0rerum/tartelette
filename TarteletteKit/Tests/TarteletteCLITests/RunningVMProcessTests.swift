import Foundation
import Testing

@testable import TarteletteCLI

@Suite("Detached VM processes")
struct RunningVMProcessTests {
  /// A child that exits immediately is reaped both by the exit source and by the post-activation
  /// check; whichever loses must never replace the real exit code with -1.
  @Test func immediateExitAlwaysReportsTheRealExitCode() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-reap-\(UUID()).log")
    defer { try? FileManager.default.removeItem(at: log) }

    for attempt in 0..<50 {
      let process = try RunningVMProcess.spawn(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 64"],
        environment: ["PATH": "/usr/bin:/bin"],
        logFile: log,
        commandLine: "sh -c 'exit 64'",
        vmName: "reap-\(attempt)"
      )
      let code = await process.waitForExit()
      #expect(code == 64, "attempt \(attempt) reported \(code)")
      #expect(process.exitCode == 64)
      #expect(!process.isRunning)
    }
  }

  /// Many threads racing to reap the same child (as the exit source and the post-activation check
  /// do) must agree on the real exit code: the ECHILD loser can't record -1.
  @Test func concurrentReapersAgreeOnTheExitCode() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("tartelette-reap-\(UUID()).log")
    defer { try? FileManager.default.removeItem(at: log) }

    for attempt in 0..<40 {
      let process = try RunningVMProcess.spawn(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 64"],
        environment: ["PATH": "/usr/bin:/bin"],
        logFile: log,
        commandLine: "sh -c 'exit 64'",
        vmName: "race-\(attempt)"
      )
      DispatchQueue.concurrentPerform(iterations: 12) { _ in
        while process.exitCode == nil { process.reap() }
      }
      #expect(process.exitCode == 64, "attempt \(attempt) recorded \(String(describing: process.exitCode))")
      #expect(await process.waitForExit() == 64)
    }
  }
}
